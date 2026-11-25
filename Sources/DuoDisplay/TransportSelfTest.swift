import Foundation
import CryptoKit
import Darwin
import os

/// `DuoDisplay --transporttest`: only the network part of a ProRes frame (~420 KB) over loopback,
/// without encoder and decoder (their run-to-run noise hides fractions of a millisecond):
/// seal → sendmsg → recv → open → reassembly, compared with the same datagrams sent in plain
/// text over a bare socket. Shows what the encryption of the media datagrams costs per frame.
enum TransportSelfTest {
    static let frameBytes = 420_000

    static func run() -> Bool {
        print("DuoDisplay Transport-Selbsttest (ProRes-großes Bild, \(frameBytes / 1000) KB, Loopback)\n")
        var ok = true
        for datagram in [DD.maxDatagramSize, 1400] {
            print("▶︎ \(datagram) B/Paket")
            let plain = measurePlain(datagram: datagram)
            let sealed = measureSealed(datagram: datagram)
            let senderOnly = measurePlain(datagram: datagram, sealedBy: .sender)
            let receiverOnly = measurePlain(datagram: datagram, sealedBy: .receiver)
            if let plain { print("  unverschlüsselt (Referenz):  \(plain.line)") }
            if let sealed { print("  verschlüsselt (DuoDisplay):  \(sealed.line)") }
            if let plain, let sealed {
                print(String(format: "  Aufschlag durch AES-GCM: Ø %+.3f ms · p50 %+.3f ms (beide Seiten teilen sich hier die Kerne)",
                             sealed.mean - plain.mean, sealed.p50 - plain.p50))
            }
            // Two Macs: each side has its own cores. Measured one side at a time.
            if let plain, let senderOnly, let receiverOnly {
                let send = senderOnly.mean - plain.mean, receive = receiverOnly.mean - plain.mean
                print(String(format: "  nur Senden verschlüsselt %+.3f ms · nur Empfang entschlüsselt %+.3f ms → zwischen zwei Macs etwa %+.3f ms",
                             send, receive, send + receive))
            }
            let passed = sealed?.allArrived == true && sealed?.intact == true
            print("  \(passed ? "✓" : "✗") alle Bilder vollständig und unverändert angekommen")
            ok = ok && passed
        }
        print(ok ? "\nERGEBNIS: OK" : "\nERGEBNIS: FEHLER")
        return ok
    }

    struct Result {
        var send: [Double] = []      // ms in send()
        var total: [Double] = []     // ms from send() start until the frame is reassembled
        var allArrived = false
        var intact = true

        private static func pct(_ v: [Double], _ p: Double) -> Double {
            let s = v.sorted()
            return s.isEmpty ? 0 : s[min(s.count - 1, Int(Double(s.count) * p))]
        }
        var mean: Double { total.isEmpty ? 0 : total.reduce(0, +) / Double(total.count) }
        var p50: Double { Self.pct(total, 0.5) }
        var line: String {
            String(format: "Senden Ø %.3f ms · bis zusammengesetzt Ø %.3f ms (p50 %.3f, p95 %.3f)",
                   send.isEmpty ? 0 : send.reduce(0, +) / Double(send.count), mean, p50, Self.pct(total, 0.95))
        }
    }

    private static let frames = 240

    private static func testFrame() -> Data {
        var data = Data(count: frameBytes)
        data.withUnsafeMutableBytes { raw in
            var x: UInt32 = 2_463_534_242
            for i in 0..<raw.count { x ^= x << 13; x ^= x >> 17; x ^= x << 5; raw[i] = UInt8(truncatingIfNeeded: x) }
        }
        return data
    }

    /// The real path: UDPVideoSender (sealing) → UDPReceiver (opening) → FrameAssembler.
    private static func measureSealed(datagram: Int) -> Result? {
        let receiver = UDPReceiver()
        guard (try? receiver.start()) != nil else { return nil }
        let key = SymmetricKey(size: .bits256)
        receiver.setOpener(MediaOpener(key: key))
        let sender = UDPVideoSender(host: "127.0.0.1", port: receiver.port, session: 1, datagramSize: datagram,
                                    interface: nil, sealer: MediaSealer(key: key))
        defer { receiver.stop(); sender.cancel() }
        let assembler = FrameAssembler()
        receiver.onDatagram = { assembler.ingest($0, now: hostTimeNs()) }
        return measure({ frame in sender.send(frame) }, assembler: assembler)
    }

    enum OneSide { case sender, receiver }

    /// Reference: the same chunk layout in plain text over a bare socket pair (what DuoDisplay did
    /// before the media datagrams were encrypted). With `sealedBy`, only one side does its part of
    /// the encryption: `.sender` – UDPVideoSender seals, this receiver only reassembles the
    /// datagrams (still sealed, the assembler only reads the chunk position); `.receiver` – the
    /// datagrams are sealed before the clock starts and sent like plain ones, UDPReceiver opens them.
    private static func measurePlain(datagram: Int, sealedBy oneSide: OneSide? = nil) -> Result? {
        if oneSide == .receiver { return measureReceiverOnly(datagram: datagram) }
        let rx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP), tx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard rx >= 0, tx >= 0 else { return nil }
        var size: Int32 = 8 << 20
        setsockopt(rx, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: 0, tv_usec: 10_000)
        setsockopt(rx, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(rx, $0, len); getsockname(rx, $0, &len); return connect(tx, $0, len) }
        }
        let assembler = FrameAssembler()
        let running = OSAllocatedUnfairLock(initialState: true)
        let stopped = DispatchSemaphore(value: 0)
        // Sender-only: each frame reserves `expected` consecutive counters (starting at 1), so the
        // datagram with counter k·expected is the last one of frame k – a lost datagram costs only
        // its own frame, not the frame boundaries of every later one.
        let expected = UInt64((frameBytes + datagram - DD.chunkHeaderSize - MediaCrypto.overhead - 1)
            / (datagram - DD.chunkHeaderSize - MediaCrypto.overhead))
        let thread = Thread {
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: 65_536, alignment: 16)
            defer { buffer.deallocate(); stopped.signal() }
            while running.withLock({ $0 }) {
                let n = recv(rx, buffer, 65_536, 0)
                guard n > 0 else { continue }
                if oneSide == .sender {
                    guard n > 1 + MediaCrypto.counterSize else { continue }
                    let counter = UInt64(bigEndian: buffer.loadUnaligned(fromByteOffset: 1, as: UInt64.self))
                    if counter % expected == 0 { assembler.onFrame?(Data(), false) }
                } else {
                    assembler.ingest(UnsafeRawBufferPointer(start: buffer, count: n), now: hostTimeNs())
                }
            }
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        defer {
            running.withLock { $0 = false }
            stopped.wait()
            close(rx); close(tx)
        }
        if oneSide == .sender {
            // Destination: the bare receive socket above.
            let sender = UDPVideoSender(host: "127.0.0.1", port: UInt16(bigEndian: addr.sin_port), session: 1,
                                        datagramSize: datagram, interface: nil, sealer: MediaSealer(key: SymmetricKey(size: .bits256)))
            defer { sender.cancel() }
            return measure({ frame in sender.send(frame) }, assembler: assembler, checkContent: false)
        }
        var frameId: UInt32 = 0
        let chunkPayload = datagram - DD.chunkHeaderSize
        return measure({ frame in
            frameId &+= 1
            let count = (frame.count + chunkPayload - 1) / chunkPayload
            frame.withUnsafeBytes { raw in
                var header = [UInt8](repeating: 0, count: DD.chunkHeaderSize)
                for i in 0..<count {
                    header[0] = DD.magic; header[1] = 1
                    withUnsafeBytes(of: frameId.littleEndian) { header.replaceSubrange(2..<6, with: $0) }
                    withUnsafeBytes(of: UInt16(i).littleEndian) { header.replaceSubrange(6..<8, with: $0) }
                    withUnsafeBytes(of: UInt16(count).littleEndian) { header.replaceSubrange(8..<10, with: $0) }
                    let start = i * chunkPayload, end = min(start + chunkPayload, frame.count)
                    header.withUnsafeMutableBytes { hdr in
                        var iov = [iovec(iov_base: hdr.baseAddress, iov_len: hdr.count),
                                   iovec(iov_base: UnsafeMutableRawPointer(mutating: raw.baseAddress! + start), iov_len: end - start)]
                        iov.withUnsafeMutableBufferPointer { iovs in
                            var msg = msghdr()
                            msg.msg_iov = iovs.baseAddress
                            msg.msg_iovlen = 2
                            while sendmsg(tx, &msg, 0) < 0, errno == ENOBUFS || errno == EAGAIN { usleep(50) }
                        }
                    }
                }
            }
        }, assembler: assembler)
    }

    /// Receiver-only: every frame is sealed before the clock starts and then sent with a bare
    /// socket like plain datagrams; UDPReceiver opens them.
    private static func measureReceiverOnly(datagram: Int) -> Result? {
        let receiver = UDPReceiver()
        guard (try? receiver.start()) != nil else { return nil }
        let key = SymmetricKey(size: .bits256)
        receiver.setOpener(MediaOpener(key: key))
        let sealer = MediaSealer(key: key)
        let assembler = FrameAssembler()
        receiver.onDatagram = { assembler.ingest($0, now: hostTimeNs()) }
        let tx = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = receiver.port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(tx, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        defer { receiver.stop(); close(tx) }
        let chunkPayload = datagram - DD.chunkHeaderSize - MediaCrypto.overhead
        var frameId: UInt32 = 0
        var datagrams: [Data] = []
        return measure({ _ in
            for d in datagrams {
                d.withUnsafeBytes { raw in
                    while send(tx, raw.baseAddress, raw.count, 0) < 0, errno == ENOBUFS || errno == EAGAIN { usleep(50) }
                }
            }
        }, prepare: { frame in
            frameId &+= 1
            let count = (frame.count + chunkPayload - 1) / chunkPayload
            datagrams = (0..<count).map { i in
                var body = Data([1])   // session
                body.appendLE(frameId)
                body.appendLE(UInt16(i))
                body.appendLE(UInt16(count))
                body.append(frame[(i * chunkPayload)..<min((i + 1) * chunkPayload, frame.count)])
                return sealer.seal(magic: DD.magic, body)!
            }
        }, assembler: assembler)
    }

    /// Sends from a userInteractive thread, like the encoder's output callback in the app.
    /// `prepare` runs before the clock starts for each frame.
    private static func measure(_ send: @escaping (Data) -> Void, prepare: ((Data) -> Void)? = nil,
                                assembler: FrameAssembler, checkContent: Bool = true) -> Result {
        var result = Result()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            result = measureHere(send, prepare: prepare, assembler: assembler, checkContent: checkContent)
            finished.signal()
        }
        thread.qualityOfService = .userInteractive
        thread.start()
        finished.wait()
        return result
    }

    private static func measureHere(_ send: (Data) -> Void, prepare: ((Data) -> Void)?,
                                    assembler: FrameAssembler, checkContent: Bool) -> Result {
        let frame = testFrame()
        let completed = DispatchSemaphore(value: 0)
        let state = OSAllocatedUnfairLock(initialState: (doneNs: UInt64(0), intact: true))
        assembler.onFrame = { data, _ in
            let now = hostTimeNs()
            let same = !checkContent || data == frame
            state.withLock { $0.doneNs = now; if !same { $0.intact = false } }
            completed.signal()
        }
        var result = Result()
        var arrived = 0
        for i in 0..<(frames + 20) {
            prepare?(frame)
            let t0 = hostTimeNs()
            send(frame)
            let t1 = hostTimeNs()
            guard completed.wait(timeout: .now() + 0.5) == .success else { continue }
            let done = state.withLock { $0.doneNs }
            if i >= 20 {   // warm-up
                result.send.append(Double(t1 - t0) / 1_000_000)
                result.total.append(Double(done &- t0) / 1_000_000)
                arrived += 1
            }
            Thread.sleep(forTimeInterval: 1.0 / 60)   // like a 60 Hz stream: the receiver idles in between
        }
        result.allArrived = arrived == frames
        result.intact = state.withLock { $0.intact }
        return result
    }
}
