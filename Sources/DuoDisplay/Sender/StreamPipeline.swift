import Foundation
import CoreMedia
import Network
import os

/// Capture → encode → UDP. Everything that touches the encoder runs on the capture queue.
final class StreamPipeline {
    struct Stats {
        var frames = 0
        var keyframes = 0
        var bytes = 0
        var packets = 0
        var encodeNsSum: UInt64 = 0
        /// Capture timestamp → frame sent (ScreenCaptureKit + waiting for the encoder + encoding + sending).
        var pipelineNsSum: UInt64 = 0
        /// Capture timestamp → frame handed to us by ScreenCaptureKit (high = WindowServer/GPU busy).
        var captureDelayNsSum: UInt64 = 0
        var captured = 0
        var skipped = 0   // captured frames replaced by a newer one while the encoder was busy
    }

    let width: Int
    let height: Int
    let fps: Int
    var lowLatencyEncoder: Bool { encoder.lowLatencyMode }
    var hardwareEncoder: Bool { encoder.hardware }
    var onError: ((Error) -> Void)?

    private let capturer = ScreenCapturer()
    private let encoder: VideoEncoder
    private let sender: UDPVideoSender
    private var lastPixelBuffer: CVPixelBuffer?
    private var lastFrameNs: UInt64 = 0
    // "Latest frame wins": at most one frame in the encoder, at most one waiting (capture queue only).
    private var encoderBusy = false
    private var waiting: (CVPixelBuffer, UInt64)?
    private let stats = OSAllocatedUnfairLock(initialState: Stats())

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrateMbps: Double,
         host: NWEndpoint.Host, port: UInt16, session: UInt8, datagramSize: Int, interface: NWInterface?,
         sealer: MediaSealer) throws {
        self.width = width
        self.height = height
        self.fps = fps
        encoder = try VideoEncoder(codec: codec, width: width, height: height, fps: fps, bitrateMbps: bitrateMbps)
        sender = UDPVideoSender(host: host, port: port, session: session, datagramSize: datagramSize, interface: interface,
                                sealer: sealer)
    }

    func start(displayID: CGDirectDisplayID, showsCursor: Bool) async throws {
        encoder.onEncoded = { [weak self] payload, keyframe, encodeNs, captureNs in
            guard let self else { return }
            let packets = self.sender.send(payload)
            let pipelineNs = hostTimeNs() &- captureNs
            self.stats.withLock {
                $0.frames += 1
                if keyframe { $0.keyframes += 1 }
                $0.bytes += payload.count
                $0.packets += packets
                $0.encodeNsSum += encodeNs
                if pipelineNs < 2_000_000_000 { $0.pipelineNsSum += pipelineNs }
            }
        }
        encoder.onFrameDone = { [weak self] in
            guard let self else { return }
            self.capturer.queue.async {
                self.encoderBusy = false
                if let (pb, captureNs) = self.waiting {
                    self.waiting = nil
                    self.submit(pb, captureNs: captureNs)
                }
            }
        }
        capturer.onFrame = { [weak self] pixelBuffer, pts in
            guard let self else { return }
            let now = hostTimeNs()
            let captureNs = min(hostTimeNs(of: pts), now)
            self.lastPixelBuffer = pixelBuffer
            self.lastFrameNs = now
            self.stats.withLock {
                $0.captured += 1
                $0.captureDelayNsSum += min(now &- captureNs, 2_000_000_000)
            }
            self.submit(pixelBuffer, captureNs: captureNs)
        }
        capturer.onError = { [weak self] error in self?.onError?(error) }
        try await capturer.start(displayID: displayID, width: width, height: height, fps: fps, showsCursor: showsCursor)
    }

    /// Capture queue. Never queues more than one frame behind the encoder: a frame that would
    /// have to wait is replaced by the next captured one, so latency cannot build up.
    private func submit(_ pixelBuffer: CVPixelBuffer, captureNs: UInt64) {
        if encoderBusy {
            if waiting != nil { stats.withLock { $0.skipped += 1 } }
            waiting = (pixelBuffer, captureNs)
            return
        }
        encoderBusy = encoder.encode(pixelBuffer, captureNs: captureNs)
    }

    /// Thread-safe. Forces the next frame to be a keyframe; if the screen is idle,
    /// re-encodes the last captured image right away so the receiver recovers immediately.
    func requestKeyframe() {
        capturer.queue.async { [self] in
            encoder.requestKeyframe()
            let frameInterval = UInt64(1_000_000_000 / max(fps, 1))
            if let pb = lastPixelBuffer, hostTimeNs() &- lastFrameNs > frameInterval + frameInterval / 2 {
                lastFrameNs = hostTimeNs()
                submit(pb, captureNs: hostTimeNs())
            }
        }
    }

    /// Releases a pipeline that was never started (e.g. replaced right after creation).
    func cancel() {
        encoder.invalidate()
        sender.cancel()
    }

    func takeStats() -> Stats {
        stats.withLock { s in
            let copy = s
            s = Stats()
            return copy
        }
    }

    func stop() async {
        await capturer.stop()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            capturer.queue.async { [self] in
                lastPixelBuffer = nil
                waiting = nil
                encoder.invalidate()
                sender.cancel()
                cont.resume()
            }
        }
    }
}
