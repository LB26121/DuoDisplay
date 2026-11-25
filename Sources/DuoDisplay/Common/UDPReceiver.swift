import Foundation
import Darwin
import os

/// Plain BSD UDP socket read by a dedicated high-priority thread.
/// (Network.framework does not let us enlarge the socket receive buffer, which matters
/// when a large keyframe arrives as a burst of hundreds of datagrams.)
///
/// The socket listens on every interface, so every datagram is opened with the current
/// connection's key first (MediaCrypto): forged, altered and replayed ones never reach
/// `onDatagram`, and without a connection (no opener) nothing does.
final class UDPReceiver {
    private(set) var port: UInt16 = 0
    private var fd: Int32 = -1
    private let running = OSAllocatedUnfairLock(initialState: false)
    private let opener = OSAllocatedUnfairLock<MediaOpener?>(initialState: nil)

    /// Called on the receive thread for each authentic datagram, as it was before sealing.
    var onDatagram: ((UnsafeRawBufferPointer) -> Void)?

    /// Any thread: the key of the current connection's incoming direction (nil = drop everything).
    func setOpener(_ newOpener: MediaOpener?) {
        opener.withLock { $0 = newOpener }
    }
    /// Called on the receive thread at least every ~10 ms.
    var onTick: (() -> Void)?

    func start() throws {
        let fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw DDError("UDP-Socket konnte nicht erstellt werden (errno \(errno))") }

        var no: Int32 = 0
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &no, socklen_t(MemoryLayout<Int32>.size))
        var size: Int32 = 8 << 20
        while size >= 256 << 10 {
            if setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &size, socklen_t(MemoryLayout<Int32>.size)) == 0 { break }
            size /= 2
        }
        var tv = timeval(tv_sec: 0, tv_usec: 10_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in6()
        addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_any
        addr.sin6_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0 else { close(fd); throw DDError("UDP-Port konnte nicht geöffnet werden (errno \(errno))") }

        var out = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &out) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        port = UInt16(bigEndian: out.sin6_port)
        self.fd = fd

        running.withLock { $0 = true }
        let thread = Thread { [self] in self.loop(fd: fd) }
        thread.name = "duodisplay.udp.recv"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Waits (≤ 10 ms) for a datagram, then also takes whatever else is already queued and opens
    /// the batch – on several cores when it is large (a ProRes frame arrives as a burst of 50–300
    /// datagrams; opening them one by one took ~0.7–2.3 ms per frame at a 60 Hz pace). The replay
    /// check and `onDatagram` stay on this thread, in arrival order.
    private func loop(fd: Int32) {
        let slot = 9_216            // macOS' default net.inet.udp.maxdgram; our datagrams are ≤ DD.maxDatagramSize
        let maxBatch = 64
        // Opening ~16 KB takes longer than handing work to other cores: two jumbo datagrams
        // are worth it, a dozen small ones too, a single sound packet never.
        let parallelFromBytes = 16_384
        let received = UnsafeMutableRawPointer.allocate(byteCount: slot * maxBatch, alignment: 16)
        let plain = UnsafeMutableRawPointer.allocate(byteCount: slot * maxBatch, alignment: 16)
        let sizes = UnsafeMutablePointer<Int>.allocate(capacity: maxBatch)
        let opened = UnsafeMutablePointer<(counter: UInt64, length: Int)?>.allocate(capacity: maxBatch)
        opened.initialize(repeating: nil, count: maxBatch)
        defer {
            received.deallocate(); plain.deallocate(); sizes.deallocate()
            opened.deinitialize(count: maxBatch); opened.deallocate()
            close(fd)
        }
        while running.withLock({ $0 }) {
            var count = 0, bytes = 0
            var n = recv(fd, received, slot, 0)
            while n > 0 {
                sizes[count] = n
                count += 1
                bytes += n
                guard count < maxBatch else { break }
                n = recv(fd, received + count * slot, slot, MSG_DONTWAIT)
            }
            if count > 0, let opener = opener.withLock({ $0 }) {
                let open = { (i: Int) in
                    opened[i] = opener.decrypt(UnsafeRawBufferPointer(start: received + i * slot, count: sizes[i]),
                                               into: UnsafeMutableRawBufferPointer(start: plain + i * slot, count: slot))
                }
                if count > 1 && bytes >= parallelFromBytes {
                    DispatchQueue.concurrentPerform(iterations: count, execute: open)
                } else {
                    for i in 0..<count { open(i) }
                }
                for i in 0..<count {
                    if let o = opened[i], opener.accept(o.counter) {
                        onDatagram?(UnsafeRawBufferPointer(start: plain + i * slot, count: o.length))
                    }
                }
            }
            onTick?()
        }
    }

    func stop() {
        running.withLock { $0 = false }
    }
}
