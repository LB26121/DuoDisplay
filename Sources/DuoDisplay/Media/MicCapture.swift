import Foundation
import AudioToolbox
import CoreAudio
import AVFoundation
import AppKit

/// Records the default input device (the iMac microphone) with a low-latency AUHAL input unit.
/// Mono, at the device's own sample rate (the MacBook side converts).
final class MicCapture {
    /// Interleaved Float32 (mono), called on the audio IO thread.
    var onAudio: ((UnsafePointer<Float>, Int, Int, Double) -> Void)?

    private var unit: AudioUnit?
    private var sampleRate: Double = 48_000
    private let capacity = 8_192
    private let buffer: UnsafeMutablePointer<Float>

    init() {
        buffer = .allocate(capacity: capacity)
        buffer.initialize(repeating: 0, count: capacity)
    }

    deinit {
        stop()
        buffer.deallocate()
    }

    var isRunning: Bool { unit != nil }

    func start() throws {
        stop()
        guard let device = CA.defaultInputDevice else { throw DDError("Kein Mikrofon gefunden") }

        var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                             componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw DDError("Keine Audio-Eingabe verfügbar") }
        var created: AudioUnit?
        try CA.check(AudioComponentInstanceNew(component, &created), "Mikrofon öffnen")
        guard let unit = created else { throw DDError("Mikrofon öffnen fehlgeschlagen") }

        do {
            var on: UInt32 = 1, off: UInt32 = 0
            let u32 = UInt32(MemoryLayout<UInt32>.size)
            try CA.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, u32), "Eingang aktivieren")
            try CA.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, u32), "Ausgang deaktivieren")
            var deviceID = device
            try CA.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                              &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "Mikrofon wählen")

            // AUHAL cannot resample on the input side: use the device's rate.
            var deviceFormat = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try CA.check(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &deviceFormat, &size), "Mikrofonformat lesen")
            sampleRate = deviceFormat.mSampleRate > 0 ? deviceFormat.mSampleRate : 48_000
            var format = AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
            try CA.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1,
                                              &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Mikrofonformat setzen")

            var frames: UInt32 = 256
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0, &frames, u32)

            var callback = AURenderCallbackStruct(inputProc: MicCapture.inputCallback,
                                                  inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CA.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0,
                                              &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Mikrofon-Callback setzen")
            try CA.check(AudioUnitInitialize(unit), "Mikrofon initialisieren")
            try CA.check(AudioOutputUnitStart(unit), "Mikrofon starten")
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
    }

    func stop() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private static let inputCallback: AURenderCallback = { refCon, flags, timeStamp, bus, frames, _ in
        let capture = Unmanaged<MicCapture>.fromOpaque(refCon).takeUnretainedValue()
        guard let unit = capture.unit, Int(frames) <= capture.capacity else { return noErr }
        var list = AudioBufferList(mNumberBuffers: 1,
                                   mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: frames * 4,
                                                         mData: UnsafeMutableRawPointer(capture.buffer)))
        let status = AudioUnitRender(unit, flags, timeStamp, bus, frames, &list)
        if status == noErr { capture.onAudio?(capture.buffer, Int(frames), 1, capture.sampleRate) }
        return noErr
    }
}

/// Camera / microphone permission helpers (AVFoundation TCC).
enum MediaPermissions {
    static func status(_ type: AVMediaType) -> AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: type) }

    static func request(_ type: AVMediaType, completion: @escaping (Bool) -> Void) {
        switch status(type) {
        case .authorized: completion(true)
        case .notDetermined: AVCaptureDevice.requestAccess(for: type) { granted in DispatchQueue.main.async { completion(granted) } }
        default: completion(false)
        }
    }

    static func openSettings(_ type: AVMediaType) {
        let pane = type == .video ? "Privacy_Camera" : "Privacy_Microphone"
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
}
