import Foundation
import ScreenCaptureKit
import CoreMedia
import os

/// Captures one display with ScreenCaptureKit, delivering NV12 frames as soon as they change.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "duodisplay.capture", qos: .userInteractive)

    /// Called on `queue` for every complete (changed) frame.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onError: ((Error) -> Void)?

    /// start() and stop() run in different tasks; stop() may come while start() is still waiting.
    private let state = OSAllocatedUnfairLock(initialState: (stream: SCStream?.none, stopped: false))

    private var isStopped: Bool { state.withLock { $0.stopped } }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int, showsCursor: Bool) async throws {
        var target: SCDisplay?
        // A freshly created virtual display needs a moment to show up.
        for _ in 0..<40 {
            guard !isStopped else { throw DDError("Bildschirmaufnahme abgebrochen") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            if let d = content.displays.first(where: { $0.displayID == displayID }) { target = d; break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let target else {
            throw DDError("Der virtuelle Bildschirm ist für ScreenCaptureKit nicht sichtbar.")
        }

        let filter = SCContentFilter(display: target, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        // Half the frame interval: the virtual display's own refresh (= fps) already caps the rate.
        // At exactly 1/fps, a frame that the window server composites a hair early (timing jitter)
        // counts as "too soon" and is held back or dropped – up to a whole frame of extra delay.
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps * 2))
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange  // encoder-native, no conversion
        config.colorSpaceName = CGColorSpace.sRGB
        config.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        config.showsCursor = showsCursor
        config.capturesAudio = false
        config.scalesToFit = false

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        guard !isStopped else { throw DDError("Bildschirmaufnahme abgebrochen") }
        try await stream.startCapture()
        // stop() during startCapture: nobody else would ever stop this stream.
        let kept = state.withLock { s -> Bool in
            guard !s.stopped else { return false }
            s.stream = stream
            return true
        }
        if !kept {
            try? await stream.stopCapture()
            throw DDError("Bildschirmaufnahme abgebrochen")
        }
    }

    func stop() async {
        let stream = state.withLock { s -> SCStream? in
            s.stopped = true
            let current = s.stream
            s.stream = nil
            return current
        }
        try? await stream?.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = (CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                                 as? [[SCStreamFrameInfo: Any]])?.first,
              let rawStatus = attachments[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }
}
