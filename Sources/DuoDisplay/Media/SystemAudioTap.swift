import Foundation
import CoreAudio
import AudioToolbox

/// Captures everything the MacBook plays (all apps except DuoDisplay itself) with a Core Audio
/// process tap and mutes it locally while tapped – so in display mode the sound comes only
/// out of the iMac. Needs macOS 14.2+ and the "System Audio Recording" permission.
final class SystemAudioTap {
    /// Interleaved Float32 frames, called on the tap's IO thread.
    var onAudio: ((UnsafePointer<Float>, Int, Int, Double) -> Void)?

    private let queue = DispatchQueue(label: "duodisplay.audio.tap", qos: .userInteractive)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var scratch = [Float](repeating: 0, count: 16_384)

    static var isSupported: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    func start() throws {
        guard #available(macOS 14.2, *) else {
            throw DDError("Ton-Übertragung braucht macOS 14.2 oder neuer auf dem MacBook.")
        }
        stop()

        // Exclude ourselves: DuoDisplay plays the iMac microphone into the virtual microphone,
        // which must neither be captured nor muted.
        var excluded: [AudioObjectID] = []
        var pid = getpid()
        var ownObject = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        if AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownObject) == noErr,
           ownObject != kAudioObjectUnknown {
            excluded.append(ownObject)
        }

        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        description.name = "DuoDisplay Ton zum iMac"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        var tap = AudioObjectID(kAudioObjectUnknown)
        try CA.check(AudioHardwareCreateProcessTap(description, &tap), "Systemton-Abgriff erstellen")
        tapID = tap

        guard let outputDevice = CA.defaultOutputDevice,
              let outputUID = CA.string(outputDevice, kAudioDevicePropertyDeviceUID) else {
            stop()
            throw DDError("Kein Ausgabegerät gefunden")
        }
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DuoDisplay Tap",
            kAudioAggregateDeviceUIDKey: "DuoDisplayTap-" + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: description.uuid.uuidString]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        do {
            try CA.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg), "Aggregat-Gerät erstellen")
        } catch {
            stop()
            throw error
        }
        aggregateID = agg

        // Small IO buffer → audio leaves the MacBook every ~5 ms instead of every ~11 ms.
        var frames: UInt32 = 256
        var bufAddr = CA.address(kAudioDevicePropertyBufferFrameSize)
        AudioObjectSetPropertyData(agg, &bufAddr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &frames)

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var formatAddr = CA.address(kAudioTapPropertyFormat)
        guard AudioObjectGetPropertyData(tap, &formatAddr, 0, nil, &formatSize, &format) == noErr,
              format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            stop()
            throw DDError("Unerwartetes Format des Systemton-Abgriffs")
        }
        let rate = format.mSampleRate
        let channels = Int(format.mChannelsPerFrame)
        let interleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        var proc: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, agg, queue) { [weak self] _, inInput, _, _, _ in
            guard let self, let onAudio = self.onAudio else { return }
            let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
            guard list.count > 0 else { return }
            if interleaved || list.count == 1 {
                let buffer = list[0]
                guard let data = buffer.mData else { return }
                let ch = interleaved ? Int(buffer.mNumberChannels) : 1
                let frames = Int(buffer.mDataByteSize) / (4 * max(ch, 1))
                onAudio(data.assumingMemoryBound(to: Float.self), frames, max(ch, 1), rate)
            } else {
                // Non-interleaved: one buffer per channel → interleave.
                let ch = min(list.count, channels)
                let frames = Int(list[0].mDataByteSize) / 4
                guard frames * ch <= self.scratch.count else { return }
                self.scratch.withUnsafeMutableBufferPointer { out in
                    for c in 0..<ch {
                        guard let src = list[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for f in 0..<frames { out[f * ch + c] = src[f] }
                    }
                    onAudio(out.baseAddress!, frames, ch, rate)
                }
            }
        }
        guard status == noErr, let proc else {
            stop()
            throw DDError("Systemton-Abgriff starten fehlgeschlagen (\(CA.fourCC(status)))")
        }
        procID = proc
        let started = AudioDeviceStart(agg, proc)
        guard started == noErr else {
            stop()
            throw DDError("Systemton-Abgriff starten fehlgeschlagen (\(CA.fourCC(started))) – bitte unter Systemeinstellungen → Datenschutz & Sicherheit → Bildschirm- & Systemaudioaufnahme DuoDisplay erlauben.")
        }
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        procID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown, #available(macOS 14.2, *) {
            AudioHardwareDestroyProcessTap(tapID)
        }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit { stop() }
}
