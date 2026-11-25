import Foundation

/// Reassembles frames from UDP chunks. Not thread-safe: use from the receive thread only.
final class FrameAssembler {
    /// A class, so a chunk is stored in place. (As a struct, `pending[id]` handed out a copy whose
    /// `chunks` array was then copied again on every write – O(n²) per frame, ~3 ms for a ProRes
    /// frame of ~300 datagrams.)
    private final class Pending {
        var chunks: [Data?]
        var received = 0
        let firstSeenNs: UInt64
        init(count: Int, now: UInt64) {
            chunks = Array(repeating: nil, count: count)
            firstSeenNs = now
        }
    }

    /// (frame bytes, a previous frame was lost)
    var onFrame: ((Data, Bool) -> Void)?
    /// An incomplete frame timed out.
    var onLoss: (() -> Void)?

    private var pending: [UInt32: Pending] = [:]
    private var lastCompleted: UInt32?
    private let staleAfterNs: UInt64

    init(staleAfterMs: Double = 50) {
        staleAfterNs = UInt64(staleAfterMs * 1_000_000)
    }

    func reset() {
        pending.removeAll()
        lastCompleted = nil
    }

    @inline(__always) private static func isNewer(_ a: UInt32, than b: UInt32) -> Bool {
        Int32(bitPattern: a &- b) > 0
    }

    func ingest(_ buf: UnsafeRawBufferPointer, now: UInt64) {
        guard buf.count > DD.chunkHeaderSize else { return }
        let frameId = buf.readLE(2, as: UInt32.self)
        let index = Int(buf.readLE(6, as: UInt16.self))
        let count = Int(buf.readLE(8, as: UInt16.self))
        guard count > 0, index < count else { return }
        if let last = lastCompleted, !Self.isNewer(frameId, than: last) { return }  // late / duplicate

        let body = UnsafeRawBufferPointer(rebasing: buf[DD.chunkHeaderSize...])

        // Fast path: single-chunk frame.
        if count == 1 {
            complete(frameId, data: Data(body))
            return
        }

        let entry: Pending
        if let existing = pending[frameId] {
            entry = existing
        } else {
            entry = Pending(count: count, now: now)
            pending[frameId] = entry
        }
        guard entry.chunks.count == count, entry.chunks[index] == nil else { return }
        entry.chunks[index] = Data(body)
        entry.received += 1

        if entry.received == count {
            pending[frameId] = nil
            var total = 0
            for c in entry.chunks { total += c!.count }
            var frame = Data(capacity: total)
            for c in entry.chunks { frame.append(c!) }
            complete(frameId, data: frame)
        }
    }

    private func complete(_ frameId: UInt32, data: Data) {
        var lost = false
        if let last = lastCompleted, frameId != last &+ 1 { lost = true }
        // Anything older that is still incomplete will never be usable.
        if !pending.isEmpty {
            let older = pending.keys.filter { !Self.isNewer($0, than: frameId) }
            if !older.isEmpty {
                lost = true
                older.forEach { pending[$0] = nil }
            }
        }
        lastCompleted = frameId
        onFrame?(data, lost)
    }

    /// Drops frames whose chunks stopped arriving (e.g. last frame before the screen went idle).
    func expireStale(now: UInt64) {
        guard !pending.isEmpty else { return }
        var expired = false
        for (id, entry) in pending where now &- entry.firstSeenNs > staleAfterNs {
            pending[id] = nil
            expired = true
        }
        if expired { onLoss?() }
    }
}
