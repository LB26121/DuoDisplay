import Foundation
import Network
import Darwin
import os

/// Splits encoded frames into datagrams and fires them out without retransmission.
/// Lost frames are handled by the receiver asking for a fresh keyframe.
///
/// Plain BSD socket, sent synchronously from the encoder's output thread with `sendmsg`.
/// Network.framework's per-datagram `send` cost ~10 µs each plus a queue hop; a ProRes frame
/// at 1400 B/datagram is ~300 datagrams, which added several milliseconds per frame.
/// Every datagram is sealed with the connection's media key (MediaCrypto) – `datagramSize`
/// includes that overhead. Large frames are sealed on several cores in batches while the
/// batches sealed so far are already being sent: on one core, sealing a ProRes frame took
/// ~0.7 ms (jumbo datagrams) to ~2.3 ms (1400 B) at a 60 Hz pace – longer than sending it.
final class UDPVideoSender {
    private let session: UInt8
    private let magic: UInt8
    private let datagramSize: Int
    private let sealer: MediaSealer
    private var frameId: UInt32 = 0
    /// Frames of at least this many datagrams are sealed in parallel; smaller ones (most HEVC
    /// frames) inline, where handing off would cost more than it saves.
    private static let parallelFrom = 8
    /// The current frame's sealed datagrams, one slot of `datagramSize` bytes each, and their
    /// lengths (0 = sealing failed). Reused across frames (send() is serial).
    private var slots = UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 16)
    private var lengths = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var slotCapacity = 0

    /// fd + destination (used with msg_name only when connect() failed). Guarded so cancel()
    /// can never close the socket in the middle of a burst.
    private struct Socket {
        var fd: Int32 = -1
        var address = sockaddr_storage()
        var addressLength: socklen_t = 0
        var connected = false
    }
    private let socket = OSAllocatedUnfairLock(initialState: Socket())

    /// Test hook: return true to drop chunk `index` of frame `frameId`.
    var dropFilter: ((UInt32, Int) -> Bool)?

    init(host: NWEndpoint.Host, port: UInt16, session: UInt8, datagramSize: Int, interface: NWInterface?,
         sealer: MediaSealer, magic: UInt8 = DD.magic) {
        self.session = session
        self.magic = magic
        self.sealer = sealer
        self.datagramSize = max(DD.minDatagramSize, min(datagramSize, DD.maxDatagramSize))

        guard let resolved = Self.resolve(host, port: port, interface: interface) else {
            ddLog.error("Cannot resolve UDP target \(String(describing: host), privacy: .public)")
            return
        }
        var address = resolved.0
        let length = resolved.1
        let family = Int32(address.ss_family)
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        func setInt(_ level: Int32, _ name: Int32, _ value: Int32) {
            var v = value
            setsockopt(fd, level, name, &v, socklen_t(MemoryLayout<Int32>.size))
        }
        setInt(SOL_SOCKET, SO_NOSIGPIPE, 1)
        setInt(SOL_SOCKET, SO_NET_SERVICE_TYPE, NET_SERVICE_TYPE_VI)   // like .interactiveVideo
        setInt(SOL_SOCKET, SO_SNDBUF, Int32(4 << 20))
        if let interface {
            let index = Int32(interface.index)
            if family == AF_INET6 { setInt(IPPROTO_IPV6, IPV6_BOUND_IF, index) } else { setInt(IPPROTO_IP, IP_BOUND_IF, index) }
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) == 0 }
        }
        let destination = address
        socket.withLock { s in
            s.fd = fd
            s.address = destination
            s.addressLength = length
            s.connected = connected
        }
    }

    deinit {
        cancel()
        slots.deallocate()
        lengths.deallocate()
    }

    /// Must be called serially (it is, from the encoder's output callback). Returns number of datagrams.
    @discardableResult
    func send(_ payload: Data) -> Int {
        frameId &+= 1
        let id = frameId
        let chunkPayload = datagramSize - DD.chunkHeaderSize - MediaCrypto.overhead
        let count = (payload.count + chunkPayload - 1) / chunkPayload
        guard count > 0, count <= Int(UInt16.max) else { return 0 }
        if count > slotCapacity {
            slots.deallocate()
            lengths.deallocate()
            slots = .allocate(byteCount: count * datagramSize, alignment: 16)
            lengths = .allocate(capacity: count)
            slotCapacity = count
        }
        let first = sealer.reserve(count)   // one counter (nonce) per datagram of this frame
        let (slots, lengths, slotSize) = (self.slots, self.lengths, datagramSize)
        let (sealer, magic, session, dropFilter) = (self.sealer, self.magic, self.session, self.dropFilter)

        socket.withLock { s in
            let fd = s.fd, connected = s.connected, addressLength = s.addressLength
            guard fd >= 0 else { return }
            payload.withUnsafeBytes { raw in
                let base = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let total = raw.count
                // Seals chunks lo..<hi into their own slots – safe on several threads at once.
                let seal = { (lo: Int, hi: Int) in
                    var body = Data(capacity: DD.chunkHeaderSize - 1 + chunkPayload)
                    for i in lo..<hi {
                        let start = i * chunkPayload
                        let end = min(start + chunkPayload, total)
                        // Plain chunk header without the magic byte (see Protocol.swift), then the slice.
                        body.removeAll(keepingCapacity: true)
                        body.append(session)
                        body.appendLE(id)
                        body.appendLE(UInt16(truncatingIfNeeded: i))
                        body.appendLE(UInt16(truncatingIfNeeded: count))
                        body.append(base + start, count: end - start)
                        lengths[i] = sealer.seal(magic: magic, body, counter: first + UInt64(i),
                                                 into: UnsafeMutableRawBufferPointer(start: slots + i * slotSize, count: slotSize)) ?? 0
                    }
                }
                withUnsafeMutablePointer(to: &s.address) { addr in
                    var msg = msghdr()
                    if !connected {
                        msg.msg_name = UnsafeMutableRawPointer(addr)
                        msg.msg_namelen = addressLength
                    }
                    func transmit(_ lo: Int, _ hi: Int) {
                        for i in lo..<hi where lengths[i] > 0 {
                            if let dropFilter, dropFilter(id, i) { continue }
                            var iov = iovec(iov_base: slots + i * slotSize, iov_len: lengths[i])
                            withUnsafeMutablePointer(to: &iov) { iovPointer in
                                msg.msg_iov = iovPointer
                                msg.msg_iovlen = 1
                                Self.sendOne(fd, &msg)
                            }
                        }
                    }
                    guard count >= Self.parallelFrom else {
                        seal(0, count)
                        transmit(0, count)
                        return
                    }
                    // This thread seals and sends the first batch itself while the workers start up
                    // on the rest. They take batches in order, so the next ones are ready first;
                    // each is sent as soon as it is sealed.
                    let batch = max(2, min(16, count / 12))
                    let batches = (count + batch - 1) / batch
                    let ready = (0..<batches).map { _ in DispatchSemaphore(value: 0) }
                    let workers = DispatchGroup()
                    DispatchQueue.global(qos: .userInteractive).async(group: workers) {
                        DispatchQueue.concurrentPerform(iterations: batches - 1) { b in
                            seal((b + 1) * batch, min((b + 2) * batch, count))
                            ready[b + 1].signal()
                        }
                    }
                    seal(0, batch)
                    transmit(0, batch)
                    for b in 1..<batches {
                        ready[b].wait()
                        transmit(b * batch, min(b * batch + batch, count))
                    }
                    workers.wait()   // nothing may touch `raw` or the slots after this returns
                }
            }
        }
        return count
    }

    /// The interface queue can briefly be full during a large burst (ENOBUFS): retry for up to ~2 ms
    /// instead of losing a chunk, which would cost the whole frame.
    @inline(__always)
    private static func sendOne(_ fd: Int32, _ msg: inout msghdr) {
        var retries = 0
        while sendmsg(fd, &msg, 0) < 0 {
            let e = errno
            guard (e == ENOBUFS || e == EAGAIN || e == EINTR), retries < 40 else { return }
            retries += 1
            if e != EINTR { usleep(50) }
        }
    }

    func cancel() {
        socket.withLock { s in
            if s.fd >= 0 { close(s.fd) }
            s.fd = -1
        }
    }

    private static func resolve(_ host: NWEndpoint.Host, port: UInt16,
                                interface: NWInterface?) -> (sockaddr_storage, socklen_t)? {
        var storage = sockaddr_storage()
        switch host {
        case .ipv4(let a):
            withUnsafeMutablePointer(to: &storage) { p in
                p.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { sin in
                    sin.pointee = sockaddr_in()
                    sin.pointee.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                    sin.pointee.sin_family = sa_family_t(AF_INET)
                    sin.pointee.sin_port = port.bigEndian
                    _ = a.rawValue.withUnsafeBytes { memcpy(&sin.pointee.sin_addr, $0.baseAddress!, 4) }
                }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
        case .ipv6(let a):
            withUnsafeMutablePointer(to: &storage) { p in
                p.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { sin in
                    sin.pointee = sockaddr_in6()
                    sin.pointee.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
                    sin.pointee.sin6_family = sa_family_t(AF_INET6)
                    sin.pointee.sin6_port = port.bigEndian
                    _ = a.rawValue.withUnsafeBytes { memcpy(&sin.pointee.sin6_addr, $0.baseAddress!, 16) }
                    if a.isLinkLocal { sin.pointee.sin6_scope_id = UInt32(a.interface?.index ?? interface?.index ?? 0) }
                }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        case .name(let name, _):
            var hints = addrinfo()
            hints.ai_socktype = SOCK_DGRAM
            hints.ai_protocol = IPPROTO_UDP
            var result: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, String(port), &hints, &result) == 0, let first = result else { return nil }
            defer { freeaddrinfo(result) }
            let length = first.pointee.ai_addrlen
            _ = withUnsafeMutableBytes(of: &storage) { memcpy($0.baseAddress!, first.pointee.ai_addr, Int(length)) }
            return (storage, length)
        @unknown default:
            return nil
        }
    }
}
