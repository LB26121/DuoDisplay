import Foundation
import CoreAudio
import CoreVideo
import CryptoKit
import os

/// `--mediatest`: audio and camera transport on this Mac, without real devices or permissions.
enum MediaSelfTest {
    static func run() -> Bool {
        print("DuoDisplay media self-test\n")
        var ok = true
        ok = audioPackets() && ok
        ok = foreignPackets() && ok
        ok = jitterDrift(senderPpm: 300) && ok
        ok = jitterDrift(senderPpm: -300) && ok
        ok = camera(width: 1920, height: 1080) && ok
        ok = camera(width: 1280, height: 720) && ok
        ok = player() && ok
        ok = environment() && ok
        print(ok ? "\nRESULT: OK" : "\nRESULT: FAILED")
        return ok
    }

    private static func check(_ name: String, _ condition: Bool) -> Bool {
        print("  \(condition ? "✓" : "✗") \(name)")
        return condition
    }

    /// Sine → AudioSender → UDP loopback → same samples, sequence without gaps.
    private static func audioPackets() -> Bool {
        print("▶︎ Audio packets (48 kHz stereo, loopback)")
        let receiver = UDPReceiver()
        do { try receiver.start() } catch { print("  UDP: \(error)"); return false }
        let key = SymmetricKey(size: .bits256)
        receiver.setOpener(MediaOpener(key: key))
        let got = OSAllocatedUnfairLock(initialState: (packets: 0, samples: [Int16](), gaps: 0, last: UInt32(0), rate: UInt32(0), channels: 0))
        receiver.onDatagram = { buf in
            guard AudioPacket.isAudio(buf) else { return }
            let seq = buf.readLE(2, as: UInt32.self)
            got.withLock { g in
                if g.last != 0 && seq != g.last &+ 1 { g.gaps += 1 }
                g.last = seq
                g.packets += 1
                g.rate = buf.readLE(6, as: UInt32.self)
                g.channels = Int(buf[10])
                for i in stride(from: AudioPacket.headerSize, to: buf.count, by: 2) {
                    g.samples.append(Int16(littleEndian: buf.loadUnaligned(fromByteOffset: i, as: Int16.self)))
                }
            }
        }
        let sender = AudioSender(host: "127.0.0.1", port: receiver.port, kind: .systemAudio, interface: nil,
                                 sealer: MediaSealer(key: key))
        // 1 s of a 440 Hz tone in irregular IO-buffer sizes (like a real device).
        var source = [Float]()
        for i in 0..<48_000 {
            let v = Float(sin(Double(i) * 2 * .pi * 440 / 48_000) * 0.5)
            source.append(v); source.append(-v)
        }
        var offset = 0
        let sizes = [512, 256, 471, 128, 1024]
        var n = 0
        while offset < 48_000 {
            let frames = min(sizes[n % sizes.count], 48_000 - offset)
            source.withUnsafeBufferPointer { sender.push($0.baseAddress! + offset * 2, frames: frames, channels: 2, sampleRate: 48_000) }
            offset += frames
            n += 1
            Thread.sleep(forTimeInterval: 0.0005)
        }
        Thread.sleep(forTimeInterval: 0.3)
        receiver.stop()
        sender.cancel()

        let g = got.withLock { $0 }
        var maxError: Float = 0
        for (i, s) in g.samples.enumerated() where i < source.count {
            maxError = max(maxError, abs(Float(s) / 32767 - source[i]))
        }
        var ok = true
        print("  \(g.packets) packets, \(g.samples.count / 2) frames, format \(g.rate) Hz / \(g.channels) channels")
        ok = check("all 5 ms packets arrived (200)", g.packets == 200) && ok
        ok = check("no gaps in the sequence", g.gaps == 0) && ok
        ok = check("samples match (max. deviation \(String(format: "%.5f", maxError)))", maxError < 0.0002) && ok
        return ok
    }

    /// Someone else on the network sends to the UDP port: plain datagrams in the old format, sealed
    /// ones with another key, and the right ones again (replay). None may reach the streams.
    private static func foreignPackets() -> Bool {
        print("▶︎ Foreign packets to the UDP port (loopback)")
        let receiver = UDPReceiver()
        do { try receiver.start() } catch { print("  UDP: \(error)"); return false }
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        receiver.onDatagram = { _ in delivered.withLock { $0 += 1 } }
        let key = SymmetricKey(size: .bits256)
        func count(_ body: () -> Void) -> Int {
            delivered.withLock { $0 = 0 }
            body()
            Thread.sleep(forTimeInterval: 0.15)
            return delivered.withLock { $0 }
        }
        // A camera frame (several chunks) and one microphone packet.
        let frame = Data(repeating: 0x5A, count: 10 * 1_000)
        var sound = Data([AudioStreamKind.microphone.rawValue])
        sound.appendLE(UInt32(1)); sound.appendLE(UInt32(48_000)); sound.append(1); sound.append(0)
        sound.append(Data(count: 480))
        var plainSound = Data([AudioPacket.magic]); plainSound.append(sound)

        var ok = true
        receiver.setOpener(MediaOpener(key: key))
        let right = MediaSealer(key: key)
        let rightVideo = UDPVideoSender(host: "127.0.0.1", port: receiver.port, session: 1, datagramSize: 1_200,
                                        interface: nil, sealer: right, magic: DD.cameraMagic)
        var chunks = 0
        let n = count { chunks = rightVideo.send(frame); sendRaw(right.seal(magic: AudioPacket.magic, sound)!, to: receiver.port) }
        ok = check("with the connection key: everything arrives (\(n) of \(chunks + 1) packets)", chunks > 1 && n == chunks + 1) && ok

        let wrongVideo = UDPVideoSender(host: "127.0.0.1", port: receiver.port, session: 1, datagramSize: 1_200,
                                        interface: nil, sealer: MediaSealer(key: SymmetricKey(size: .bits256)), magic: DD.cameraMagic)
        ok = check("other key: nothing arrives",
                   count { wrongVideo.send(frame); sendRaw(MediaSealer(key: SymmetricKey(size: .bits256)).seal(magic: AudioPacket.magic, sound)!, to: receiver.port) } == 0) && ok
        ok = check("unencrypted (old format): nothing arrives", count { sendRaw(plainSound, to: receiver.port) } == 0) && ok

        let sealed = right.seal(magic: AudioPacket.magic, sound)!
        _ = count { sendRaw(sealed, to: receiver.port) }
        ok = check("intercepted packet resent: rejected", count { sendRaw(sealed, to: receiver.port) } == 0) && ok
        var swapped = right.seal(magic: AudioPacket.magic, sound)!
        swapped[0] = DD.magic
        ok = check("packet kind rewritten: rejected", count { sendRaw(swapped, to: receiver.port) } == 0) && ok

        receiver.setOpener(nil)
        ok = check("without connection: nothing arrives",
                   count { rightVideo.send(frame); sendRaw(right.seal(magic: AudioPacket.magic, sound)!, to: receiver.port) } == 0) && ok
        receiver.stop()
        rightVideo.cancel()
        wrongVideo.cancel()
        return ok
    }

    /// One datagram from a plain socket, like any other program on the network could send it.
    private static func sendRaw(_ datagram: Data, to port: UInt16) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        datagram.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// The two Macs' clocks drift apart: the buffer must stay near its target without underruns.
    private static func jitterDrift(senderPpm: Double) -> Bool {
        print("▶︎ Jitter buffer, clock drift \(senderPpm > 0 ? "+" : "")\(Int(senderPpm)) ppm, 10 minutes simulated")
        let rate = 48_000.0
        let buffer = AudioJitterBuffer(channels: 2, sampleRate: rate, targetMs: 20)
        let senderRate = rate * (1 + senderPpm / 1_000_000)
        let block = [Float](repeating: 0.1, count: 240 * 2)
        var out = [Float](repeating: 0, count: 256 * 2)
        var sent = 0.0, consumed = 0
        var minLevel = Int.max, maxLevel = 0
        let simulatedSeconds = 600.0
        let steps = Int(simulatedSeconds * rate / 256)
        var underrunsAfterStart = 0
        for step in 0..<steps {
            consumed += 256
            // Sender delivers in bursts of ~10.7 ms (512 frames → two packets), like a real tap.
            let due = Double(consumed) * senderRate / rate + 960   // 20 ms head start
            while sent + 512 <= due {
                block.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 240) }
                block.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 240) }
                block.withUnsafeBufferPointer { buffer.write($0.baseAddress!, frames: 32) }
                sent += 512
            }
            let before = buffer.underruns
            out.withUnsafeMutableBufferPointer { buffer.read(into: $0.baseAddress!, frames: 256) }
            if step > 200 {
                if buffer.underruns > before { underrunsAfterStart += 1 }
                minLevel = min(minLevel, buffer.count)
                maxLevel = max(maxLevel, buffer.count)
            }
        }
        let toMs = { (frames: Int) in Double(frames) * 1000 / rate }
        print(String(format: "  fill level %.1f–%.1f ms (target 20 ms), %d corrections", toMs(minLevel), toMs(maxLevel), buffer.adjustments))
        var ok = true
        ok = check("no dropouts", underrunsAfterStart == 0) && ok
        ok = check("latency stays below 45 ms", toMs(maxLevel) < 45) && ok
        return ok
    }

    /// Camera path: NV12 frames → HEVC → UDP (camera magic) → reassembly → decode to 1080p BGRA.
    private static func camera(width: Int, height: Int) -> Bool {
        print("▶︎ Camera \(width)×\(height) → HEVC → UDP → 1920×1080 BGRA")
        let receiver = UDPReceiver()
        do { try receiver.start() } catch { print("  UDP: \(error)"); return false }
        let stream = CameraStreamReceiver()
        let result = OSAllocatedUnfairLock(initialState: (frames: 0, sizeOK: true, format: OSType(0), keyRequests: 0))
        stream.onFrame = { pb in
            result.withLock {
                $0.frames += 1
                $0.format = CVPixelBufferGetPixelFormatType(pb)
                if CVPixelBufferGetWidth(pb) != VirtualCameraConfig.width || CVPixelBufferGetHeight(pb) != VirtualCameraConfig.height { $0.sizeOK = false }
            }
        }
        stream.onKeyframeNeeded = { result.withLock { $0.keyRequests += 1 } }
        let key = SymmetricKey(size: .bits256)
        receiver.setOpener(MediaOpener(key: key))
        receiver.onDatagram = { stream.handle($0) }
        receiver.onTick = { stream.tick(active: true) }

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(codec: .hevc, width: width, height: height, fps: 30, bitrateMbps: 12, lowLatencyRateControl: false)
        } catch { print("  \(error.localizedDescription)"); return false }
        let sender = UDPVideoSender(host: "127.0.0.1", port: receiver.port, session: 3, datagramSize: 1400,
                                    interface: nil, sealer: MediaSealer(key: key), magic: DD.cameraMagic)
        encoder.onEncoded = { payload, _, _, _ in sender.send(payload) }

        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { return false }
        let total = 45
        for i in 0..<total {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { continue }
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!
            memset(y, Int32(16 + (i * 5) % 200), CVPixelBufferGetBytesPerRowOfPlane(pb, 0) * height)
            memset(CVPixelBufferGetBaseAddressOfPlane(pb, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(pb, [])
            encoder.encode(pb, captureNs: hostTimeNs())
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
        Thread.sleep(forTimeInterval: 0.4)
        receiver.stop()
        sender.cancel()
        encoder.invalidate()

        let r = result.withLock { $0 }
        var ok = true
        print("  \(r.frames)/\(total) frames decoded, keyframe requests: \(r.keyRequests)")
        ok = check("all frames arrived and decoded", r.frames == total) && ok
        ok = check("output 1920×1080 BGRA (virtual camera format)", r.sizeOK && r.format == kCVPixelFormatType_32BGRA) && ok
        return ok
    }

    /// Real output device: silent packets for 1.5 s – the output unit must start and drain the buffer.
    private static func player() -> Bool {
        print("▶︎ Playback on the default output device (silence, 1.5 s)")
        let player = AudioPlayer(kind: .systemAudio, outputChannels: 2, targetMs: 20)
        let errors = OSAllocatedUnfairLock(initialState: [String]())
        player.onError = { e in errors.withLock { $0.append(e) } }
        player.start()
        var packet = Data([AudioPacket.magic, AudioStreamKind.systemAudio.rawValue])
        packet.appendLE(UInt32(1)); packet.appendLE(UInt32(48_000)); packet.append(2); packet.append(0)
        packet.append(Data(count: 240 * 2 * 2))
        var levels: [Int] = []
        for i in 0..<300 {   // 5 ms each
            packet.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: UInt32(i + 1).littleEndian, toByteOffset: 2, as: UInt32.self)
                player.ingest(UnsafeRawBufferPointer(raw))
            }
            Thread.sleep(forTimeInterval: 0.005)
            if i > 100, let level = player.bufferedFrames { levels.append(level) }
        }
        player.stop()
        Thread.sleep(forTimeInterval: 0.1)
        let e = errors.withLock { $0 }
        let maxMs = Double(levels.max() ?? 0) / 48
        print(String(format: "  fill level max. %.1f ms", maxMs) + (e.isEmpty ? "" : " · errors: \(e.joined(separator: ", "))"))
        var ok = check("output started, no errors", e.isEmpty && !levels.isEmpty)
        // Sleep() jitter makes this loose; a stuck output would grow towards 1 s.
        ok = check("output drains the buffer (stays below 120 ms)", maxMs < 120) && ok
        return ok
    }

    /// Prerequisites on this Mac that can be checked without asking for permissions.
    private static func environment() -> Bool {
        print("▶︎ Environment")
        var pid = getpid()
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = CA.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        let status = AudioObjectGetPropertyData(CA.system, &addr, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        var ok = check("own process can be excluded from the audio tap (Core Audio object \(object))",
                       status == noErr && object != kAudioObjectUnknown)
        ok = check("audio tap available (macOS 14.2+)", SystemAudioTap.isSupported) && ok
        print("  ℹ︎ virtual microphone installed: \(VirtualMic.device != nil ? "yes" : "no")")
        print("  ℹ︎ camera: \(CameraCapture.preferredDevice()?.localizedName ?? "none")")
        return ok
    }
}
