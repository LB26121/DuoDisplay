import Foundation
import VideoToolbox
import CoreMedia

/// Hardware video encoder configured for minimum latency:
/// real-time mode, no B-frames, no frame delay, keyframes only on demand (ProRes: every frame).
///
/// Measured on an M4 (3024×1890): HEVC ≈ 7.7 ms/frame, H.264 ≈ 12.5 ms, H.264 with Apple's
/// "low-latency rate control" ≈ 15.5 ms. That mode only smooths frame sizes for slow links,
/// which Thunderbolt does not need, so it is off by default.
final class VideoEncoder {
    let codec: VideoCodec
    private(set) var lowLatencyMode = false
    private(set) var hardware = true
    private var session: VTCompressionSession?
    private var forceKeyframeNext = true   // touched only on the capture queue

    /// (payload, isKeyframe, encode duration in ns, captureNs of the frame) — called on VideoToolbox'
    /// output thread, in order.
    var onEncoded: ((Data, Bool, UInt64, UInt64) -> Void)?

    init(codec: VideoCodec, width: Int, height: Int, fps: Int, bitrateMbps: Double,
         lowLatencyRateControl: Bool = ProcessInfo.processInfo.environment["DD_LLRC"] != nil) throws {
        self.codec = codec
        var created: VTCompressionSession?
        var status: OSStatus = -1
        for lowLatency in (lowLatencyRateControl && !codec.isIntraOnly ? [true, false] : [false]) {
            var spec: [CFString: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true]
            if lowLatency { spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true }
            created = nil
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: codec.cmCodecType, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &created)
            if status == noErr, created != nil { lowLatencyMode = lowLatency; break }
        }
        guard status == noErr, let session = created else {
            throw DDError("Video-Encoder (\(codec.label) \(width)×\(height)) konnte nicht erstellt werden: \(status)")
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        let bitrate = Int(bitrateMbps * 1_000_000)
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        // ProRes: fixed quality per frame, every frame a keyframe – no profile, bitrate or GOP to set.
        if !codec.isIntraOnly {
            set(kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
            set(kVTCompressionPropertyKey_MaxFrameDelayCount, NSNumber(value: 0))
            set(kVTCompressionPropertyKey_ProfileLevel,
                codec == .h264 ? kVTProfileLevel_H264_High_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel)
            if codec == .h264 { set(kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC) }
            set(kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bitrate))
            set(kVTCompressionPropertyKey_DataRateLimits, [NSNumber(value: Double(bitrate) / 8 * 1.5), NSNumber(value: 1.0)] as CFArray)
            set(kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: fps * 3600))
            set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: 3600))
        }
        set(kVTCompressionPropertyKey_ColorPrimaries, kCVImageBufferColorPrimaries_ITU_R_709_2)
        set(kVTCompressionPropertyKey_TransferFunction, kCVImageBufferTransferFunction_ITU_R_709_2)
        set(kVTCompressionPropertyKey_YCbCrMatrix, kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        VTCompressionSessionPrepareToEncodeFrames(session)
        var usingHardware: CFTypeRef?
        if VTSessionCopyProperty(session, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                 allocator: nil, valueOut: &usingHardware) == noErr,
           let flag = usingHardware as? Bool {
            hardware = flag
        }
    }

    deinit { invalidate() }

    func invalidate() {
        guard let session else { return }
        self.session = nil
        VTCompressionSessionInvalidate(session)
    }

    /// Call on the capture queue.
    func requestKeyframe() { forceKeyframeNext = true }

    /// Called on VideoToolbox' output thread after every submitted frame (encoded or dropped).
    var onFrameDone: (() -> Void)?

    /// Call on the capture queue. Returns false if the frame was not accepted (no callback follows).
    @discardableResult
    func encode(_ pixelBuffer: CVPixelBuffer, captureNs: UInt64) -> Bool {
        guard let session else { return false }
        var properties: CFDictionary?
        if forceKeyframeNext {
            forceKeyframeNext = false
            properties = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
        }
        let submitted = hostTimeNs()
        let pts = CMTime(value: CMTimeValue(submitted), timescale: 1_000_000_000)
        let status = VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: properties, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard let self else { return }
            if status == noErr, let sampleBuffer {
                self.emit(sampleBuffer, captureNs: captureNs, encodeNs: hostTimeNs() &- submitted)
            }
            self.onFrameDone?()
        }
        if status != noErr {
            forceKeyframeNext = true
            return false
        }
        return true
    }

    private func emit(_ sampleBuffer: CMSampleBuffer, captureNs: UInt64, encodeNs: UInt64) {
        var keyframe = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[String: Any]],
           let notSync = attachments.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            keyframe = !notSync
        }
        var parameterSets: [Data] = []
        if keyframe, let format = CMSampleBufferGetFormatDescription(sampleBuffer) {
            parameterSets = FrameCodec.parameterSets(of: format, codec: codec)
        }
        guard let data = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }
        let payload = FrameCodec.buildPayload(codec: codec, keyframe: keyframe, captureNs: captureNs,
                                              parameterSets: parameterSets, sampleData: data)
        onEncoded?(payload, keyframe, encodeNs, captureNs)
    }
}
