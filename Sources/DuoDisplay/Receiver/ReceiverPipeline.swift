import Foundation
import os

struct ReceiverStats {
    var fps: Double
    var mbps: Double
    var latencyMs: Double?
    var latencyMaxMs: Double?
    var lost: Int
    var keyframeRequests: Int

    var line: String {
        var s = String(format: "%.0f fps · %.1f Mbit/s", fps, mbps)
        if let latencyMs {
            s += String(format: " · Aufnahme→Bild Ø %.1f ms (max %.1f)", latencyMs, latencyMaxMs ?? latencyMs)
        }
        s += " · Verluste \(lost) · Keyframe-Anfragen \(keyframeRequests)"
        return s
    }
}

/// Everything that happens per datagram. Runs entirely on the UDP receive thread,
/// except the small shared state guarded by `shared`.
final class ReceiverPipeline {
    private struct Shared {
        var active = false
        var session: UInt8 = 0
        var clockOffsetNs: Int64 = 0   // sender clock − receiver clock
        var hasClock = false
        var sendControl: ((ControlMessage) -> Void)?
    }

    let renderer: VideoRenderer
    var onStats: ((ReceiverStats) -> Void)?

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private let assembler = FrameAssembler()
    private var currentSession: UInt8 = 0
    private var lastKeyframeRequestNs: UInt64 = 0
    private var lastTickNs: UInt64 = 0
    private var lastStatsNs: UInt64 = hostTimeNs()
    private var frameArrivalNs: UInt64 = 0

    // Stats (receive thread only)
    private var statFrames = 0
    private var statBytes = 0
    /// Capture (sender) → handed to the GPU (here); written from the render queue.
    private let latency = OSAllocatedUnfairLock(initialState: (sum: 0.0, count: 0, max: 0.0))
    private var statLost = 0
    private var statKeyframeRequests = 0

    init(renderer: VideoRenderer) {
        self.renderer = renderer
        assembler.onFrame = { [unowned self] data, lost in self.frameReady(data, lost: lost) }
        renderer.presenter.onPresented = { [unowned self] captureNs in self.recordPresented(captureNs) }
        assembler.onLoss = { [unowned self] in
            self.statLost += 1
            self.renderer.markLoss()
            self.requestKeyframe()
        }
    }

    // MARK: Control side (any thread)

    func activate(session: UInt8, sendControl: @escaping (ControlMessage) -> Void) {
        shared.withLock {
            $0.active = true
            $0.session = session
            $0.hasClock = false
            $0.sendControl = sendControl
        }
    }

    func deactivate() {
        shared.withLock {
            $0.active = false
            $0.sendControl = nil
        }
    }

    func setClockOffset(_ offsetNs: Int64) {
        shared.withLock {
            $0.clockOffsetNs = offsetNs
            $0.hasClock = true
        }
    }

    // MARK: Receive thread

    func handle(_ buf: UnsafeRawBufferPointer) {
        guard buf.count > DD.chunkHeaderSize, buf[0] == DD.magic else { return }
        let (active, session) = shared.withLock { ($0.active, $0.session) }
        guard active, buf[1] == session else { return }
        if currentSession != session {
            currentSession = session
            assembler.reset()
            renderer.reset()
            lastKeyframeRequestNs = 0
        }
        statBytes += buf.count
        frameArrivalNs = hostTimeNs()
        assembler.ingest(buf, now: frameArrivalNs)
    }

    func tick() {
        let now = hostTimeNs()
        guard now &- lastTickNs > 5_000_000 else { return }
        lastTickNs = now
        assembler.expireStale(now: now)

        let active = shared.withLock { $0.active }
        // Nothing decodable yet (e.g. the very first keyframe got lost while the screen is idle).
        if active && renderer.waitingForKeyframe && now &- lastKeyframeRequestNs > 300_000_000 {
            requestKeyframe()
        }
        if now &- lastStatsNs >= 1_000_000_000 {
            emitStats(now: now, active: active)
        }
    }

    private func frameReady(_ data: Data, lost: Bool) {
        if lost { statLost += 1 }
        switch renderer.handle(data, lossBefore: lost) {
        case .submitted:
            statFrames += 1
        case .needKeyframe:
            requestKeyframe()
        case .invalid:
            break
        }
    }

    /// Render queue.
    private func recordPresented(_ captureNs: UInt64) {
        let (hasClock, offset) = shared.withLock { ($0.hasClock, $0.clockOffsetNs) }
        guard hasClock else { return }
        let senderNow = Int64(bitPattern: hostTimeNs()) &+ offset
        let ms = Double(senderNow &- Int64(bitPattern: captureNs)) / 1_000_000
        guard ms > -5 && ms < 2_000 else { return }
        latency.withLock {
            $0.sum += ms
            $0.count += 1
            $0.max = Swift.max($0.max, ms)
        }
    }

    private func requestKeyframe() {
        let now = hostTimeNs()
        guard now &- lastKeyframeRequestNs > 100_000_000 else { return }
        lastKeyframeRequestNs = now
        statKeyframeRequests += 1
        let send = shared.withLock { $0.sendControl }
        send?(ControlMessage(.keyframeRequest))
    }

    private func emitStats(now: UInt64, active: Bool) {
        let seconds = Double(now &- lastStatsNs) / 1_000_000_000
        lastStatsNs = now
        let lat = latency.withLock { l -> (sum: Double, count: Int, max: Double) in
            let copy = l
            l = (0, 0, 0)
            return copy
        }
        let stats = ReceiverStats(
            fps: Double(statFrames) / seconds,
            mbps: Double(statBytes) * 8 / 1_000_000 / seconds,
            latencyMs: lat.count > 0 ? lat.sum / Double(lat.count) : nil,
            latencyMaxMs: lat.count > 0 ? lat.max : nil,
            lost: statLost,
            keyframeRequests: statKeyframeRequests)
        statFrames = 0; statBytes = 0
        statLost = 0; statKeyframeRequests = 0
        guard active else { return }
        ddLog.notice("Empfang: \(stats.line, privacy: .public) · gezeigt \(lat.count)")
        onStats?(stats)
        var msg = ControlMessage(.stats)
        msg.fps = stats.fps
        msg.mbps = stats.mbps
        msg.latencyMs = stats.latencyMs
        msg.latencyMaxMs = stats.latencyMaxMs
        msg.lost = stats.lost
        shared.withLock { $0.sendControl }?(msg)
    }
}
