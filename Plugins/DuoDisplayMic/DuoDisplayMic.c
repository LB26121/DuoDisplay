// DuoDisplayMic – a tiny Core Audio loopback driver (AudioServerPlugIn).
//
// It publishes one device, "iMac Microphone (DuoDisplay)", with a mono 48 kHz input stream
// (what FaceTime, Zoom & Co. record from) and a matching output stream. The DuoDisplay app
// plays the microphone audio it receives from the iMac into the output side; everything
// written there comes back out of the input side, sample-accurately, ~2 IO buffers later.
//
// Custom device property 'ddcl' (CFArray of CFNumber): the process IDs that are currently
// running IO on the device. The app polls it to see whether an app other than itself is
// recording, and only then asks the iMac to switch its microphone on.
//
// Structure follows Apple's "NullAudio" sample driver. Install: copy DuoDisplayMic.driver to
// /Library/Audio/Plug-Ins/HAL and restart coreaudiod (the app does this on request).

#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdbool.h>
#include <string.h>

// MARK: - Constants

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream_Input = 3,
    kObjectID_Stream_Output = 4,
};

#define kDevice_Name          "iMac Microphone (DuoDisplay)"
#define kManufacturer_Name    "DuoDisplay"
#define kDevice_UID           "DuoDisplayMic_UID"
#define kDevice_ModelUID      "DuoDisplayMic_ModelUID"
#define kSampleRate           48000.0
#define kChannels             1
#define kBytesPerFrame        (sizeof(Float32) * kChannels)
#define kRingFrames           16384          // also the zero-timestamp period (~341 ms)
#define kSelectorClients      'ddcl'
#define kMaxClients           64

// MARK: - State

static pthread_mutex_t gMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;

static Float64 gHostTicksPerFrame = 0;
static UInt64 gAnchorHostTime = 0;
static UInt64 gNumberTimeStamps = 0;
static UInt32 gIORunning = 0;

static Float32 gRing[kRingFrames * kChannels];
static Float64 gRingStamp[kRingFrames];        // sample time each slot was written for

typedef struct { UInt32 clientID; pid_t pid; bool running; } Client;
static Client gClients[kMaxClients];
static UInt32 gClientCount = 0;

// MARK: - Interface declarations

static HRESULT DD_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG DD_AddRef(void* inDriver);
static ULONG DD_Release(void* inDriver);
static OSStatus DD_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus DD_CreateDevice(AudioServerPlugInDriverRef, CFDictionaryRef, const AudioServerPlugInClientInfo*, AudioObjectID*);
static OSStatus DD_DestroyDevice(AudioServerPlugInDriverRef, AudioObjectID);
static OSStatus DD_AddDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus DD_RemoveDeviceClient(AudioServerPlugInDriverRef, AudioObjectID, const AudioServerPlugInClientInfo*);
static OSStatus DD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static OSStatus DD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef, AudioObjectID, UInt64, void*);
static Boolean DD_HasProperty(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*);
static OSStatus DD_IsPropertySettable(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, Boolean*);
static OSStatus DD_GetPropertyDataSize(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32*);
static OSStatus DD_GetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, UInt32*, void*);
static OSStatus DD_SetPropertyData(AudioServerPlugInDriverRef, AudioObjectID, pid_t, const AudioObjectPropertyAddress*, UInt32, const void*, UInt32, const void*);
static OSStatus DD_StartIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus DD_StopIO(AudioServerPlugInDriverRef, AudioObjectID, UInt32);
static OSStatus DD_GetZeroTimeStamp(AudioServerPlugInDriverRef, AudioObjectID, UInt32, Float64*, UInt64*, UInt64*);
static OSStatus DD_WillDoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, Boolean*, Boolean*);
static OSStatus DD_BeginIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);
static OSStatus DD_DoIOOperation(AudioServerPlugInDriverRef, AudioObjectID, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*, void*, void*);
static OSStatus DD_EndIOOperation(AudioServerPlugInDriverRef, AudioObjectID, UInt32, UInt32, UInt32, const AudioServerPlugInIOCycleInfo*);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    DD_QueryInterface, DD_AddRef, DD_Release,
    DD_Initialize, DD_CreateDevice, DD_DestroyDevice,
    DD_AddDeviceClient, DD_RemoveDeviceClient,
    DD_PerformDeviceConfigurationChange, DD_AbortDeviceConfigurationChange,
    DD_HasProperty, DD_IsPropertySettable, DD_GetPropertyDataSize, DD_GetPropertyData, DD_SetPropertyData,
    DD_StartIO, DD_StopIO, DD_GetZeroTimeStamp,
    DD_WillDoIOOperation, DD_BeginIOOperation, DD_DoIOOperation, DD_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// MARK: - Factory

void* DDMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* DDMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        return gDriverRef;
    }
    return NULL;
}

// MARK: - IUnknown

static HRESULT DD_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gMutex);
        ++gRefCount;
        pthread_mutex_unlock(&gMutex);
        *outInterface = gDriverRef;
        result = 0;
    }
    CFRelease(requested);
    return result;
}

static ULONG DD_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    ULONG r = ++gRefCount;
    pthread_mutex_unlock(&gMutex);
    return r;
}

static ULONG DD_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gMutex);
    if (gRefCount > 0) --gRefCount;
    ULONG r = gRefCount;
    pthread_mutex_unlock(&gMutex);
    return r;
}

// MARK: - Basic operations

static OSStatus DD_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    Float64 ticksPerSecond = 1e9 * (Float64)tb.denom / (Float64)tb.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    memset(gRing, 0, sizeof(gRing));
    for (UInt32 i = 0; i < kRingFrames; ++i) gRingStamp[i] = -1;
    return 0;
}

static OSStatus DD_CreateDevice(AudioServerPlugInDriverRef d, CFDictionaryRef desc, const AudioServerPlugInClientInfo* ci, AudioObjectID* out) {
    (void)d; (void)desc; (void)ci; (void)out;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DD_DestroyDevice(AudioServerPlugInDriverRef d, AudioObjectID id) {
    (void)d; (void)id;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DD_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gClientCount < kMaxClients) {
        gClients[gClientCount++] = (Client){ inClientInfo->mClientID, inClientInfo->mProcessID, false };
    }
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus DD_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    for (UInt32 i = 0; i < gClientCount; ++i) {
        if (gClients[i].clientID == inClientInfo->mClientID) {
            gClients[i] = gClients[--gClientCount];
            break;
        }
    }
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus DD_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}

static OSStatus DD_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef d, AudioObjectID id, UInt64 a, void* i) {
    (void)d; (void)id; (void)a; (void)i;
    return 0;
}

// MARK: - Helpers

static AudioStreamBasicDescription StreamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannels;
    f.mBitsPerChannel = 32;
    return f;
}

static bool IsStream(AudioObjectID id) { return id == kObjectID_Stream_Input || id == kObjectID_Stream_Output; }

/// Streams of the device for a scope: input, output or both (global).
static UInt32 StreamsForScope(AudioObjectPropertyScope scope, AudioObjectID out[2]) {
    UInt32 n = 0;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeInput) out[n++] = kObjectID_Stream_Input;
    if (scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput) out[n++] = kObjectID_Stream_Output;
    return n;
}

static CFArrayRef CopyRunningClientPIDs(void) {
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    pthread_mutex_lock(&gMutex);
    for (UInt32 i = 0; i < gClientCount; ++i) {
        if (!gClients[i].running) continue;
        SInt32 pid = gClients[i].pid;
        CFNumberRef num = CFNumberCreate(NULL, kCFNumberSInt32Type, &pid);
        CFArrayAppendValue(array, num);
        CFRelease(num);
    }
    pthread_mutex_unlock(&gMutex);
    return array;
}

// MARK: - Properties

static Boolean DD_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a) {
    (void)inClientPID;
    if (inDriver != gDriverRef || a == NULL) return false;
    switch (inObjectID) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
        case kAudioPlugInPropertyResourceBundle:
            return true;
        }
        return false;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyName:
        case kAudioObjectPropertyManufacturer:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList:
        case kAudioObjectPropertyCustomPropertyInfoList:
        case kAudioDevicePropertyDeviceUID:
        case kAudioDevicePropertyModelUID:
        case kAudioDevicePropertyTransportType:
        case kAudioDevicePropertyRelatedDevices:
        case kAudioDevicePropertyClockDomain:
        case kAudioDevicePropertyDeviceIsAlive:
        case kAudioDevicePropertyDeviceIsRunning:
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertyStreams:
        case kAudioDevicePropertySafetyOffset:
        case kAudioDevicePropertyNominalSampleRate:
        case kAudioDevicePropertyAvailableNominalSampleRates:
        case kAudioDevicePropertyIsHidden:
        case kAudioDevicePropertyZeroTimeStampPeriod:
        case kAudioDevicePropertyPreferredChannelsForStereo:
        case kAudioDevicePropertyPreferredChannelLayout:
        case kSelectorClients:
            return true;
        }
        return false;
    case kObjectID_Stream_Input:
    case kObjectID_Stream_Output:
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass:
        case kAudioObjectPropertyClass:
        case kAudioObjectPropertyOwner:
        case kAudioObjectPropertyOwnedObjects:
        case kAudioStreamPropertyIsActive:
        case kAudioStreamPropertyDirection:
        case kAudioStreamPropertyTerminalType:
        case kAudioStreamPropertyStartingChannel:
        case kAudioStreamPropertyLatency:
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return true;
        }
        return false;
    }
    return false;
}

static OSStatus DD_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, Boolean* outIsSettable) {
    if (inDriver != gDriverRef || outIsSettable == NULL) return kAudioHardwareBadObjectError;
    if (!DD_HasProperty(inDriver, inObjectID, inClientPID, a)) return kAudioHardwareUnknownPropertyError;
    // Fixed format; the stream formats are "settable" only to the one format we support.
    *outIsSettable = IsStream(inObjectID) && (a->mSelector == kAudioStreamPropertyVirtualFormat ||
                                              a->mSelector == kAudioStreamPropertyPhysicalFormat);
    return 0;
}

static OSStatus DD_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32* outDataSize) {
    (void)qs; (void)qd;
    if (inDriver != gDriverRef || outDataSize == NULL) return kAudioHardwareBadObjectError;
    if (!DD_HasProperty(inDriver, inObjectID, inClientPID, a)) return kAudioHardwareUnknownPropertyError;
    AudioObjectID streams[2];
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:   // kAudioStreamPropertyLatency == kAudioDevicePropertyLatency
        *outDataSize = sizeof(UInt32);
        return 0;
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioPlugInPropertyResourceBundle:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
        *outDataSize = sizeof(CFStringRef);
        return 0;
    case kSelectorClients:
        *outDataSize = sizeof(CFPropertyListRef);
        return 0;
    case kAudioObjectPropertyOwnedObjects:
        if (inObjectID == kObjectID_PlugIn) *outDataSize = sizeof(AudioObjectID);
        else if (inObjectID == kObjectID_Device) *outDataSize = StreamsForScope(a->mScope, streams) * sizeof(AudioObjectID);
        else *outDataSize = 0;
        return 0;
    case kAudioPlugInPropertyDeviceList:
    case kAudioDevicePropertyRelatedDevices:
        *outDataSize = sizeof(AudioObjectID);
        return 0;
    case kAudioDevicePropertyStreams:
        *outDataSize = StreamsForScope(a->mScope, streams) * sizeof(AudioObjectID);
        return 0;
    case kAudioObjectPropertyControlList:
        *outDataSize = 0;
        return 0;
    case kAudioObjectPropertyCustomPropertyInfoList:
        *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
        return 0;
    case kAudioDevicePropertyNominalSampleRate:
        *outDataSize = sizeof(Float64);
        return 0;
    case kAudioDevicePropertyAvailableNominalSampleRates:
        *outDataSize = sizeof(AudioValueRange);
        return 0;
    case kAudioDevicePropertyPreferredChannelsForStereo:
        *outDataSize = 2 * sizeof(UInt32);
        return 0;
    case kAudioDevicePropertyPreferredChannelLayout:
        *outDataSize = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
        return 0;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *outDataSize = sizeof(AudioStreamBasicDescription);
        return 0;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        *outDataSize = sizeof(AudioStreamRangedDescription);
        return 0;
    }
    return kAudioHardwareUnknownPropertyError;
}

#define REQUIRE_SIZE(n) do { if (inDataSize < (n)) return kAudioHardwareBadPropertySizeError; *outDataSize = (UInt32)(n); } while (0)
#define PUT_U32(v) do { REQUIRE_SIZE(sizeof(UInt32)); *(UInt32*)outData = (v); return 0; } while (0)
#define PUT_STR(s) do { REQUIRE_SIZE(sizeof(CFStringRef)); *(CFStringRef*)outData = CFSTR(s); return 0; } while (0)

static OSStatus DD_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    if (inDriver != gDriverRef || outDataSize == NULL || outData == NULL) return kAudioHardwareBadObjectError;
    if (!DD_HasProperty(inDriver, inObjectID, inClientPID, a)) return kAudioHardwareUnknownPropertyError;
    AudioObjectID streams[2];

    if (inObjectID == kObjectID_PlugIn) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT_U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT_U32(kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: PUT_U32(kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: PUT_STR(kManufacturer_Name);
        case kAudioPlugInPropertyResourceBundle: PUT_STR("");
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioObjectID)) {
                *(AudioObjectID*)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
            }
            return 0;
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            REQUIRE_SIZE(sizeof(AudioObjectID));
            AudioObjectID result = kAudioObjectUnknown;
            if (inQualifierDataSize == sizeof(CFStringRef) && inQualifierData != NULL) {
                CFStringRef uid = *(const CFStringRef*)inQualifierData;
                if (uid != NULL && CFStringCompare(uid, CFSTR(kDevice_UID), 0) == kCFCompareEqualTo) result = kObjectID_Device;
            }
            *(AudioObjectID*)outData = result;
            return 0;
        }
        }
    } else if (inObjectID == kObjectID_Device) {
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT_U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT_U32(kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: PUT_U32(kObjectID_PlugIn);
        case kAudioObjectPropertyName: PUT_STR(kDevice_Name);
        case kAudioObjectPropertyManufacturer: PUT_STR(kManufacturer_Name);
        case kAudioDevicePropertyDeviceUID: PUT_STR(kDevice_UID);
        case kAudioDevicePropertyModelUID: PUT_STR(kDevice_ModelUID);
        case kAudioDevicePropertyTransportType: PUT_U32(kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyClockDomain: PUT_U32(0);
        case kAudioDevicePropertyDeviceIsAlive: PUT_U32(1);
        case kAudioDevicePropertyDeviceIsRunning: {
            pthread_mutex_lock(&gMutex);
            UInt32 running = gIORunning > 0;
            pthread_mutex_unlock(&gMutex);
            PUT_U32(running);
        }
        // Only the input side may become the default (microphone); never the default speaker.
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: PUT_U32(a->mScope == kAudioObjectPropertyScopeInput ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: PUT_U32(0);
        case kAudioDevicePropertyLatency: PUT_U32(0);
        case kAudioDevicePropertySafetyOffset: PUT_U32(0);
        case kAudioDevicePropertyIsHidden: PUT_U32(0);
        case kAudioDevicePropertyZeroTimeStampPeriod: PUT_U32(kRingFrames);
        case kAudioObjectPropertyControlList:
            *outDataSize = 0;
            return 0;
        case kAudioObjectPropertyOwnedObjects:
        case kAudioDevicePropertyStreams: {
            UInt32 n = StreamsForScope(a->mScope, streams);
            UInt32 fit = inDataSize / sizeof(AudioObjectID);
            if (fit < n) n = fit;
            memcpy(outData, streams, n * sizeof(AudioObjectID));
            *outDataSize = n * sizeof(AudioObjectID);
            return 0;
        }
        case kAudioDevicePropertyRelatedDevices:
            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioObjectID)) {
                *(AudioObjectID*)outData = kObjectID_Device;
                *outDataSize = sizeof(AudioObjectID);
            }
            return 0;
        case kAudioObjectPropertyCustomPropertyInfoList: {
            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioServerPlugInCustomPropertyInfo)) {
                AudioServerPlugInCustomPropertyInfo* info = (AudioServerPlugInCustomPropertyInfo*)outData;
                info->mSelector = kSelectorClients;
                info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
                info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
                *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            }
            return 0;
        }
        case kSelectorClients:
            REQUIRE_SIZE(sizeof(CFPropertyListRef));
            *(CFPropertyListRef*)outData = CopyRunningClientPIDs();
            return 0;
        case kAudioDevicePropertyNominalSampleRate:
            REQUIRE_SIZE(sizeof(Float64));
            *(Float64*)outData = kSampleRate;
            return 0;
        case kAudioDevicePropertyAvailableNominalSampleRates:
            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioValueRange)) {
                ((AudioValueRange*)outData)->mMinimum = kSampleRate;
                ((AudioValueRange*)outData)->mMaximum = kSampleRate;
                *outDataSize = sizeof(AudioValueRange);
            }
            return 0;
        case kAudioDevicePropertyPreferredChannelsForStereo:
            REQUIRE_SIZE(2 * sizeof(UInt32));
            ((UInt32*)outData)[0] = 1;
            ((UInt32*)outData)[1] = kChannels >= 2 ? 2 : 1;
            return 0;
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannels * sizeof(AudioChannelDescription));
            REQUIRE_SIZE(size);
            AudioChannelLayout* layout = (AudioChannelLayout*)outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = kChannels;
            for (UInt32 i = 0; i < kChannels; ++i) {
                layout->mChannelDescriptions[i].mChannelLabel = kChannels == 1 ? kAudioChannelLabel_Mono : kAudioChannelLabel_Left + i;
            }
            return 0;
        }
        }
    } else if (IsStream(inObjectID)) {
        bool input = inObjectID == kObjectID_Stream_Input;
        switch (a->mSelector) {
        case kAudioObjectPropertyBaseClass: PUT_U32(kAudioObjectClassID);
        case kAudioObjectPropertyClass: PUT_U32(kAudioStreamClassID);
        case kAudioObjectPropertyOwner: PUT_U32(kObjectID_Device);
        case kAudioObjectPropertyOwnedObjects:
            *outDataSize = 0;
            return 0;
        case kAudioStreamPropertyIsActive: PUT_U32(1);
        case kAudioStreamPropertyDirection: PUT_U32(input ? 1 : 0);
        case kAudioStreamPropertyTerminalType: PUT_U32(input ? kAudioStreamTerminalTypeMicrophone : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: PUT_U32(1);
        case kAudioStreamPropertyLatency: PUT_U32(0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            REQUIRE_SIZE(sizeof(AudioStreamBasicDescription));
            *(AudioStreamBasicDescription*)outData = StreamFormat();
            return 0;
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            *outDataSize = 0;
            if (inDataSize >= sizeof(AudioStreamRangedDescription)) {
                AudioStreamRangedDescription* r = (AudioStreamRangedDescription*)outData;
                r->mFormat = StreamFormat();
                r->mSampleRateRange.mMinimum = kSampleRate;
                r->mSampleRateRange.mMaximum = kSampleRate;
                *outDataSize = sizeof(AudioStreamRangedDescription);
            }
            return 0;
        }
    }
    return kAudioHardwareUnknownPropertyError;
}

static OSStatus DD_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientPID, const AudioObjectPropertyAddress* a, UInt32 qs, const void* qd, UInt32 inDataSize, const void* inData) {
    (void)qs; (void)qd;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (!DD_HasProperty(inDriver, inObjectID, inClientPID, a)) return kAudioHardwareUnknownPropertyError;
    if (IsStream(inObjectID) && (a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        if (inDataSize != sizeof(AudioStreamBasicDescription) || inData == NULL) return kAudioHardwareBadPropertySizeError;
        const AudioStreamBasicDescription* f = (const AudioStreamBasicDescription*)inData;
        AudioStreamBasicDescription ours = StreamFormat();
        if (f->mSampleRate != ours.mSampleRate || f->mChannelsPerFrame != ours.mChannelsPerFrame ||
            f->mFormatID != ours.mFormatID || f->mBitsPerChannel != ours.mBitsPerChannel) {
            return kAudioDeviceUnsupportedFormatError;
        }
        return 0;
    }
    return kAudioHardwareUnsupportedOperationError;
}

// MARK: - IO

static OSStatus DD_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIORunning == 0) {
        gNumberTimeStamps = 0;
        gAnchorHostTime = mach_absolute_time();
        for (UInt32 i = 0; i < kRingFrames; ++i) gRingStamp[i] = -1;
    }
    ++gIORunning;
    for (UInt32 i = 0; i < gClientCount; ++i) {
        if (gClients[i].clientID == inClientID) gClients[i].running = true;
    }
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus DD_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    if (gIORunning > 0) --gIORunning;
    for (UInt32 i = 0; i < gClientCount; ++i) {
        if (gClients[i].clientID == inClientID) gClients[i].running = false;
    }
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus DD_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerRing = gHostTicksPerFrame * (Float64)kRingFrames;
    UInt64 next = gAnchorHostTime + (UInt64)((Float64)(gNumberTimeStamps + 1) * ticksPerRing);
    if (next <= now) ++gNumberTimeStamps;
    *outSampleTime = (Float64)(gNumberTimeStamps * kRingFrames);
    *outHostTime = gAnchorHostTime + (UInt64)((Float64)gNumberTimeStamps * ticksPerRing);
    *outSeed = 1;
    pthread_mutex_unlock(&gMutex);
    return 0;
}

static OSStatus DD_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    bool will = inOperationID == kAudioServerPlugInIOOperationReadInput || inOperationID == kAudioServerPlugInIOOperationWriteMix;
    if (outWillDo) *outWillDo = will;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return 0;
}

static OSStatus DD_BeginIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 o, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)c; (void)o; (void)n; (void)i;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}

static OSStatus DD_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inStreamObjectID; (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    if (ioMainBuffer == NULL) return 0;
    Float32* buffer = (Float32*)ioMainBuffer;

    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        Float64 start = inIOCycleInfo->mOutputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            Float64 t = start + f;
            UInt32 slot = (UInt32)((UInt64)t % kRingFrames);
            for (UInt32 c = 0; c < kChannels; ++c) gRing[slot * kChannels + c] = buffer[f * kChannels + c];
            gRingStamp[slot] = t;
        }
    } else if (inOperationID == kAudioServerPlugInIOOperationReadInput) {
        Float64 start = inIOCycleInfo->mInputTime.mSampleTime;
        for (UInt32 f = 0; f < inIOBufferFrameSize; ++f) {
            Float64 t = start + f;
            if (t < 0) {
                for (UInt32 c = 0; c < kChannels; ++c) buffer[f * kChannels + c] = 0;
                continue;
            }
            UInt32 slot = (UInt32)((UInt64)t % kRingFrames);
            // Only audio written for exactly this sample time counts – never replay stale audio.
            bool fresh = gRingStamp[slot] == t;
            for (UInt32 c = 0; c < kChannels; ++c) buffer[f * kChannels + c] = fresh ? gRing[slot * kChannels + c] : 0;
        }
    }
    return 0;
}

static OSStatus DD_EndIOOperation(AudioServerPlugInDriverRef d, AudioObjectID id, UInt32 c, UInt32 o, UInt32 n, const AudioServerPlugInIOCycleInfo* i) {
    (void)c; (void)o; (void)n; (void)i;
    if (d != gDriverRef || id != kObjectID_Device) return kAudioHardwareBadObjectError;
    return 0;
}
