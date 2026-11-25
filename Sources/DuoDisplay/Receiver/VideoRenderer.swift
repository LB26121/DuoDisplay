import Foundation
import CoreMedia
import VideoToolbox
import os

/// Keyframe/loss state machine shared by the on-screen renderer and the self test.
final class FrameGate {
    enum Output {
        case sample(CMSampleBuffer, captureNs: UInt64, keyframe: Bool)
        case needKeyframe
        case invalid
    }

    private var format: CMVideoFormatDescription?
    private(set) var waitingForKeyframe = true

    func reset() {
        format = nil
        waitingForKeyframe = true
    }

    func markLoss() { waitingForKeyframe = true }

    func process(_ data: Data, lossBefore: Bool) -> Output {
        guard let frame = FrameCodec.parse(data) else { return .invalid }
        if lossBefore { waitingForKeyframe = true }
        if frame.keyframe {
            if let newFormat = FrameCodec.makeFormatDescription(codec: frame.codec, parameterSets: frame.parameterSets) {
                if format == nil || !CMFormatDescriptionEqual(newFormat, otherFormatDescription: format) {
                    format = newFormat
                }
            }
            waitingForKeyframe = format == nil
        }
        if waitingForKeyframe { return .needKeyframe }
        guard let format, let sample = FrameCodec.makeSampleBuffer(from: data, range: frame.sampleRange, format: format) else {
            return .invalid
        }
        return .sample(sample, captureNs: frame.captureNs, keyframe: frame.keyframe)
    }
}

/// Hardware-decodes with VideoToolbox (real-time, asynchronous) and hands every decoded image
/// straight to the Metal presenter – no display-layer queue, no timebase, no V-Sync wait.
final class VideoRenderer {
    enum Result {
        case submitted
        case needKeyframe
        case invalid
    }

    let presenter: MetalPresenter
    private let gate = FrameGate()
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private let decodeFailed = OSAllocatedUnfairLock(initialState: false)

    var waitingForKeyframe: Bool { gate.waitingForKeyframe }

    init() {
        guard let presenter = MetalPresenter() else { fatalError("Metal ist auf diesem Mac nicht verfügbar") }
        self.presenter = presenter
    }

    /// Receive-thread only.
    func reset() {
        gate.reset()
        decodeFailed.withLock { $0 = false }
    }

    /// Receive-thread only.
    func markLoss() { gate.markLoss() }

    func clear() { presenter.clear() }

    /// Receive-thread only.
    func handle(_ data: Data, lossBefore: Bool) -> Result {
        if decodeFailed.withLock({ let f = $0; $0 = false; return f }) { gate.markLoss() }
        switch gate.process(data, lossBefore: lossBefore) {
        case .invalid:
            return .invalid
        case .needKeyframe:
            return .needKeyframe
        case let .sample(sample, captureNs, _):
            guard let format = CMSampleBufferGetFormatDescription(sample), let session = decoder(for: format) else {
                gate.markLoss()
                return .needKeyframe
            }
            let presenter = self.presenter
            let failed = decodeFailed
            // No ._1xRealTimePlayback: that flag lets the decoder drop into a low-power mode that only
            // has to keep up with the frame rate. On an M4 (3024×1890 HEVC) decoding then took
            // Ø 6.3 ms / p95 13 ms instead of Ø 3.7 ms / p95 6.7 ms.
            let status = VTDecompressionSessionDecodeFrame(
                session, sampleBuffer: sample,
                flags: [._EnableAsynchronousDecompression],
                infoFlagsOut: nil
            ) { status, _, imageBuffer, _, _ in
                if status == noErr, let imageBuffer {
                    presenter.display(imageBuffer, captureNs: captureNs)
                } else if status != noErr {
                    failed.withLock { $0 = true }
                }
            }
            if status != noErr {
                invalidateDecoder()
                gate.markLoss()
                return .needKeyframe
            }
            return .submitted
        }
    }

    private func decoder(for format: CMFormatDescription) -> VTDecompressionSession? {
        if let session, let sessionFormat, CMFormatDescriptionEqual(format, otherFormatDescription: sessionFormat) {
            return session
        }
        invalidateDecoder()
        // ProRes is 4:2:2 inside; asking for 4:2:0 adds a conversion (decode Ø 1.6 → 4.3 ms on an M4).
        // The shader reads the chroma plane with normalized coordinates, so both layouts just work.
        let isProRes = CMFormatDescriptionGetMediaSubType(format) == VideoCodec.prores.cmCodecType
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: isProRes ? kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange
                                                       : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        let spec: [CFString: Any] = [kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true]
        var created: VTDecompressionSession?
        guard VTDecompressionSessionCreate(allocator: kCFAllocatorDefault, formatDescription: format,
                                           decoderSpecification: spec as CFDictionary,
                                           imageBufferAttributes: attributes as CFDictionary,
                                           outputCallback: nil, decompressionSessionOut: &created) == noErr,
              let created else { return nil }
        VTSessionSetProperty(created, key: kVTDecompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        session = created
        sessionFormat = format
        return created
    }

    private func invalidateDecoder() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        sessionFormat = nil
    }
}
