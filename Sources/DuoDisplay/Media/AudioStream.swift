import Foundation
import Network
import AudioToolbox
import CoreAudio
import os

/// Audio datagrams (UDP, sent on the same port as the video, sealed like it – MediaCrypto;
/// the layout below is the plain datagram):
///
///   [0]      magic 0xA5
///   [1]      stream (AudioStreamKind)
///   [2..5]   sequence number (UInt32 LE)
///   [6..9]   sample rate (UInt32 LE)
///   [10]     channel count
///   [11]     reserved
///   [12...]  Int16 LE samples, interleaved – about 5 ms per datagram
///
/// Uncompressed on purpose: ~1.5 Mbit/s for 48 kHz stereo is nothing on Thunderbolt and
/// avoids every millisecond of codec delay.
enum AudioStreamKind: UInt8 {
    case systemAudio = 0   // MacBook → iMac speakers
    case microphone = 1    // iMac microphone → virtual microphone on the MacBook
}

enum AudioPacket {
    static let magic: UInt8 = 0xA5
    static let headerSize = 12
    static let maxPayload = 1_100      // + header + MediaCrypto.overhead stays below a 1500-byte MTU

    static func isAudio(_ buf: UnsafeRawBufferPointer) -> Bool {
        buf.count > headerSize && buf[0] == magic
    }
}

// MARK: - Sender

/// Cuts interleaved Float32 audio into ~5 ms Int16 datagrams. `push` must be called serially.
final class AudioSender {
    private let connection: NWConnection
    private let kind: AudioStreamKind
    private let sealer: MediaSealer
    private var sequence: UInt32 = 0
    private var pending: [Int16] = []
    private var rate: UInt32 = 0
    private var channels = 0
    private var framesPerPacket = 240

    init(host: NWEndpoint.Host, port: UInt16, kind: AudioStreamKind, interface: NWInterface?, sealer: MediaSealer) {
        let params = NWParameters.udp
        params.serviceClass = .interactiveVoice
        params.includePeerToPeer = false
        if let interface { params.requiredInterface = interface }
        self.kind = kind
        self.sealer = sealer
        connection = NWConnection(host: host, port: NWEndpoint.Port(rawValue: port)!, using: params)
        connection.start(queue: DispatchQueue(label: "duodisplay.audio.send", qos: .userInteractive))
    }

    func push(_ samples: UnsafePointer<Float>, frames: Int, channels: Int, sampleRate: Double) {
        guard frames > 0, channels > 0 else { return }
        let r = UInt32(sampleRate.rounded())
        if r != rate || channels != self.channels {
            rate = r
            self.channels = channels
            pending.removeAll(keepingCapacity: true)
            framesPerPacket = max(32, min(Int(r) / 200, AudioPacket.maxPayload / (2 * channels)))
        }
        let count = frames * channels
        pending.reserveCapacity(pending.count + count)
        for i in 0..<count {
            let v = max(-1, min(1, samples[i]))
            pending.append(Int16(v * 32767))
        }
        let packetSamples = framesPerPacket * channels
        var offset = 0
        while pending.count - offset >= packetSamples {
            sequence &+= 1
            // The plain datagram after the magic byte.
            var body = Data(capacity: AudioPacket.headerSize - 1 + packetSamples * 2)
            body.append(kind.rawValue)
            body.appendLE(sequence)
            body.appendLE(rate)
            body.append(UInt8(channels))
            body.append(0)
            pending[offset..<(offset + packetSamples)].withUnsafeBytes { body.append(contentsOf: $0) }   // little endian host
            if let datagram = sealer.seal(magic: AudioPacket.magic, body) {
                connection.send(content: datagram, completion: .idempotent)
            }
            offset += packetSamples
        }
        if offset > 0 { pending.removeFirst(offset) }
    }

    func cancel() { connection.cancel() }
}

// MARK: - Jitter buffer

/// Ring buffer between network and audio output. Keeps the fill level around `target` by
/// skipping or repeating a single frame per callback (clock drift between the two Macs),
/// re-buffers after an underrun and drops audio that piled up (e.g. after a hiccup).
/// Not thread-safe – AudioPlayer guards it with a lock.
final class AudioJitterBuffer {
    let channels: Int
    let targetFrames: Int
    private let capacity: Int
    private let tolerance: Int
    private let maxExcess: Int
    private let ring: UnsafeMutablePointer<Float>
    private var readIndex = 0
    private(set) var count = 0          // frames
    private var primed = false
    private var smoothed = 0.0
    private(set) var underruns = 0
    private(set) var adjustments = 0

    init(channels: Int, sampleRate: Double, targetMs: Double) {
        self.channels = channels
        targetFrames = Int(sampleRate * targetMs / 1000)
        capacity = Int(sampleRate)                      // 1 s
        tolerance = max(16, Int(sampleRate * 0.003))   // ±3 ms
        maxExcess = Int(sampleRate * 0.08)              // > target + 80 ms → drop
        ring = .allocate(capacity: capacity * channels)
        ring.initialize(repeating: 0, count: capacity * channels)
    }

    deinit { ring.deallocate() }

    var levelMs: Double { Double(count) * 1000 / Double(max(capacity, 1)) }

    func write(_ samples: UnsafePointer<Float>, frames: Int) {
        var frames = frames
        var src = samples
        if frames > capacity {
            src += (frames - capacity) * channels
            frames = capacity
        }
        if count + frames > capacity {   // overflow: forget the oldest
            let drop = count + frames - capacity
            readIndex = (readIndex + drop) % capacity
            count -= drop
        }
        var writeIndex = (readIndex + count) % capacity
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, capacity - writeIndex)
            (ring + writeIndex * channels).update(from: src, count: n * channels)
            src += n * channels
            writeIndex = (writeIndex + n) % capacity
            remaining -= n
        }
        count += frames
    }

    func read(into out: UnsafeMutablePointer<Float>, frames: Int) {
        if !primed {
            guard count >= targetFrames else {
                out.update(repeating: 0, count: frames * channels)
                return
            }
            primed = true
            smoothed = Double(count)
        }
        if count > targetFrames + maxExcess {
            skip(count - targetFrames)
            smoothed = Double(targetFrames)
        }
        smoothed = smoothed * 0.97 + Double(count) * 0.03
        var adjust = 0
        if smoothed > Double(targetFrames + tolerance) { adjust = 1 }
        else if smoothed < Double(targetFrames - tolerance) && frames > 1 { adjust = -1 }

        let needed = frames + adjust
        if count < needed {
            let have = count
            copy(into: out, frames: have)
            (out + have * channels).update(repeating: 0, count: (frames - have) * channels)
            primed = false
            underruns += 1
            return
        }
        switch adjust {
        case 1:
            copy(into: out, frames: frames)
            skip(1)
            adjustments += 1
        case -1:
            copy(into: out, frames: frames - 1)
            let last = out + (frames - 2) * channels
            (out + (frames - 1) * channels).update(from: last, count: channels)
            adjustments += 1
        default:
            copy(into: out, frames: frames)
        }
    }

    private func copy(into out: UnsafeMutablePointer<Float>, frames: Int) {
        var dst = out
        var remaining = frames
        while remaining > 0 {
            let n = min(remaining, capacity - readIndex)
            dst.update(from: ring + readIndex * channels, count: n * channels)
            dst += n * channels
            readIndex = (readIndex + n) % capacity
            remaining -= n
        }
        count -= frames
    }

    private func skip(_ frames: Int) {
        let n = min(frames, count)
        readIndex = (readIndex + n) % capacity
        count -= n
    }
}

// MARK: - Player

/// Plays one incoming audio stream on an output device (default output, or a device by UID)
/// with low latency. `ingest` is called on the UDP receive thread.
final class AudioPlayer {
    private struct State {
        var buffer: AudioJitterBuffer?
        var rate: UInt32 = 0
        var channels = 0
        var reconfiguring = false
        var lastPacketNs: UInt64 = 0
        var lastSequence: UInt32 = 0
        var lost = 0
        var enabled = false
        var retryAfterNs: UInt64 = 0   // output setup failed: don't retry on every packet
    }

    let kind: AudioStreamKind
    private let deviceUID: String?
    private let outputChannels: Int
    private let targetMs: Double
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "duodisplay.audio.player", qos: .userInteractive)
    private var unit: AudioUnit?             // queue only
    var onError: ((String) -> Void)?

    init(kind: AudioStreamKind, deviceUID: String? = nil, outputChannels: Int, targetMs: Double) {
        self.kind = kind
        self.deviceUID = deviceUID
        self.outputChannels = outputChannels
        self.targetMs = targetMs
    }

    deinit {
        if let unit {
            AudioOutputUnitStop(unit)
            AudioComponentInstanceDispose(unit)
        }
    }

    /// Accept packets; the output unit starts with the first one.
    func start() { state.withLock { $0.enabled = true } }

    /// Stop playing and release the output device.
    func stop() {
        state.withLock {
            $0.enabled = false
            $0.buffer = nil
            $0.rate = 0
        }
        queue.async { self.disposeUnit() }
    }

    /// True while packets keep arriving.
    var isReceiving: Bool {
        let last = state.withLock { $0.lastPacketNs }
        return last != 0 && hostTimeNs() &- last < 1_000_000_000
    }

    /// Frames waiting in the jitter buffer (nil while the output is not set up).
    var bufferedFrames: Int? { state.withLock { $0.buffer?.count } }

    func takeLost() -> Int { state.withLock { let n = $0.lost; $0.lost = 0; return n } }

    /// Receive thread.
    func ingest(_ buf: UnsafeRawBufferPointer) {
        guard AudioPacket.isAudio(buf), buf[1] == kind.rawValue else { return }
        let sequence = buf.readLE(2, as: UInt32.self)
        let rate = buf.readLE(6, as: UInt32.self)
        let channels = Int(buf[10])
        let samples = (buf.count - AudioPacket.headerSize) / 2
        guard rate >= 8_000, rate <= 192_000, channels > 0, channels <= 8, samples >= channels else { return }
        let frames = samples / channels
        let outChannels = outputChannels

        withUnsafeTemporaryAllocation(of: Float.self, capacity: frames * outChannels) { out in
            let base = buf.baseAddress! + AudioPacket.headerSize
            for f in 0..<frames {
                @inline(__always) func sample(_ c: Int) -> Float {
                    Float(Int16(littleEndian: base.loadUnaligned(fromByteOffset: (f * channels + c) * 2, as: Int16.self))) / 32768
                }
                if outChannels == channels {
                    for c in 0..<channels { out[f * outChannels + c] = sample(c) }
                } else if channels == 1 {
                    let v = sample(0)
                    for c in 0..<outChannels { out[f * outChannels + c] = v }
                } else if outChannels == 1 {
                    var sum: Float = 0
                    for c in 0..<channels { sum += sample(c) }
                    out[f] = sum / Float(channels)
                } else {
                    for c in 0..<outChannels { out[f * outChannels + c] = sample(min(c, channels - 1)) }
                }
            }

            let samplesOut = out.baseAddress!
            let needsSetup = state.withLock { s -> Bool in
                guard s.enabled else { return false }
                s.lastPacketNs = hostTimeNs()
                if s.lastSequence != 0, sequence &- s.lastSequence > 1, sequence &- s.lastSequence < 1000 {
                    s.lost += Int(sequence &- s.lastSequence &- 1)
                }
                s.lastSequence = sequence
                if s.rate != rate || s.channels != channels || s.buffer == nil {
                    guard !s.reconfiguring, s.lastPacketNs >= s.retryAfterNs else { return false }
                    s.reconfiguring = true
                    s.rate = rate
                    s.channels = channels
                    return true
                }
                s.buffer?.write(samplesOut, frames: frames)
                return false
            }
            if needsSetup { queue.async { self.setup(rate: rate) } }
        }
    }

    // MARK: Output unit (queue)

    private func setup(rate: UInt32) {
        disposeUnit()
        // stop() may have run since this setup was requested: then don't open the device again.
        let enabled = state.withLock { s -> Bool in
            if !s.enabled { s.reconfiguring = false }
            return s.enabled
        }
        guard enabled else { return }
        let buffer = AudioJitterBuffer(channels: outputChannels, sampleRate: Double(rate), targetMs: targetMs)
        do {
            unit = try makeUnit(rate: Double(rate))
            state.withLock {
                $0.buffer = $0.enabled ? buffer : nil
                $0.reconfiguring = false
                $0.retryAfterNs = 0
            }
        } catch {
            state.withLock {
                $0.reconfiguring = false
                $0.rate = 0
                $0.retryAfterNs = hostTimeNs() &+ 1_000_000_000
            }
            onError?(error.localizedDescription)
        }
    }

    private func disposeUnit() {
        guard let unit else { return }
        self.unit = nil
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    private func makeUnit(rate: Double) throws -> AudioUnit {
        var deviceID: AudioObjectID?
        if let deviceUID {
            guard let id = CA.device(uid: deviceUID) else { throw DDError("Audio device “\(deviceUID)” not found") }
            deviceID = id
        }
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: deviceID == nil ? kAudioUnitSubType_DefaultOutput : kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &desc) else { throw DDError("No audio output available") }
        var created: AudioUnit?
        try CA.check(AudioComponentInstanceNew(component, &created), "create audio output")
        guard let unit = created else { throw DDError("Could not create audio output") }
        do {
            if var deviceID {
                try CA.check(AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                                  &deviceID, UInt32(MemoryLayout<AudioObjectID>.size)), "select audio device")
            }
            let ch = UInt32(outputChannels)
            var format = AudioStreamBasicDescription(
                mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 4 * ch, mFramesPerPacket: 1, mBytesPerFrame: 4 * ch,
                mChannelsPerFrame: ch, mBitsPerChannel: 32, mReserved: 0)
            try CA.check(AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0,
                                              &format, UInt32(MemoryLayout<AudioStreamBasicDescription>.size)), "Audioformat setzen")
            var callback = AURenderCallbackStruct(inputProc: AudioPlayer.render,
                                                  inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
            try CA.check(AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0,
                                              &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)), "Audio-Callback setzen")
            var frames: UInt32 = 256   // ~5 ms IO buffer
            AudioUnitSetProperty(unit, kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
                                 &frames, UInt32(MemoryLayout<UInt32>.size))
            try CA.check(AudioUnitInitialize(unit), "initialize audio output")
            try CA.check(AudioOutputUnitStart(unit), "start audio output")
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        return unit
    }

    private static let render: AURenderCallback = { refCon, _, _, _, frames, ioData in
        let player = Unmanaged<AudioPlayer>.fromOpaque(refCon).takeUnretainedValue()
        guard let list = UnsafeMutableAudioBufferListPointer(ioData), let data = list[0].mData else { return noErr }
        let out = data.assumingMemoryBound(to: Float.self)
        let channels = player.outputChannels
        player.state.withLock { s in
            if let buffer = s.buffer {
                buffer.read(into: out, frames: Int(frames))
            } else {
                out.update(repeating: 0, count: Int(frames) * channels)
            }
        }
        return noErr
    }
}
