import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo
import VideoToolbox
import SystemExtensions
import os

/// Constants shared with the camera extension (Sources/DuoDisplayCamera).
enum VirtualCameraConfig {
    static let deviceUID = "DuoDisplay-iMacCamera"
    static let width = 1920
    static let height = 1080
    static let demandSelector = fourCharCode("ddon")
    static var extensionIdentifier: String { (Bundle.main.bundleIdentifier ?? "local.duodisplay.DuoDisplay") + ".CameraExtension" }
}

// MARK: - Sink (MacBook → camera extension)

/// Talks to the "iMac-Kamera (DuoDisplay)" device published by the camera extension:
/// reads whether an app is using the camera and pushes decoded frames into its sink stream.
final class VirtualCameraSink {
    private struct Sink {
        var device: CMIOObjectID = 0
        var stream: CMIOStreamID = 0
        var queue: CMSimpleQueue?
        var running = false
    }

    private let sink = OSAllocatedUnfairLock(initialState: Sink())

    private static func address(_ selector: Int, scope: Int = kCMIOObjectPropertyScopeGlobal) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(scope),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    private static func objects(_ object: CMIOObjectID, _ selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return ids
    }

    private static func string(_ object: CMIOObjectID, _ selector: UInt32) -> String? {
        var addr = CMIOObjectPropertyAddress(mSelector: selector, mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                             mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        guard CMIOObjectHasProperty(object, &addr) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// Finds the virtual camera and its sink stream. Main thread (polled).
    private static func locate() -> (CMIOObjectID, CMIOStreamID)? {
        for device in objects(CMIOObjectID(kCMIOObjectSystemObject), kCMIOHardwarePropertyDevices)
        where string(device, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID)) == VirtualCameraConfig.deviceUID {
            let streams = objects(device, kCMIODevicePropertyStreams)
            // The sink is the stream that carries our demand property.
            if let sink = streams.first(where: { string($0, VirtualCameraConfig.demandSelector) != nil }) {
                return (device, sink)
            }
            if streams.count >= 2 { return (device, streams[1]) }
        }
        return nil
    }

    /// Polled on the main thread: is the extension installed, is any app using the camera?
    func poll() -> (installed: Bool, demanded: Bool) {
        let current = sink.withLock { $0 }
        var device = current.device, stream = current.stream
        if device == 0 || Self.string(stream, VirtualCameraConfig.demandSelector) == nil {
            stopFeeding()
            guard let found = Self.locate() else { return (false, false) }
            (device, stream) = found
            sink.withLock {
                $0.device = device
                $0.stream = stream
            }
        }
        let demanded = Self.string(stream, VirtualCameraConfig.demandSelector) == "1"
        return (true, demanded)
    }

    /// False again once `poll` had to stop feeding (the extension restarted, new object IDs).
    var isFeeding: Bool { sink.withLock { $0.running } }

    /// Main thread.
    func startFeeding() -> Bool {
        let (device, stream, running) = sink.withLock { ($0.device, $0.stream, $0.running) }
        if running { return true }
        guard device != 0 else { return false }
        var queue: Unmanaged<CMSimpleQueue>?
        guard CMIOStreamCopyBufferQueue(stream, { _, _, _ in }, nil, &queue) == noErr, let queue else { return false }
        let q = queue.takeRetainedValue()
        guard CMIODeviceStartStream(device, stream) == noErr else { return false }
        sink.withLock {
            $0.queue = q
            $0.running = true
        }
        return true
    }

    /// Main thread.
    func stopFeeding() {
        let (device, stream, running) = sink.withLock { s -> (CMIOObjectID, CMIOStreamID, Bool) in
            let r = (s.device, s.stream, s.running)
            s.running = false
            s.queue = nil
            return r
        }
        if running { CMIODeviceStopStream(device, stream) }
    }

    /// Any thread: hands one frame to the extension (dropped if the queue is full).
    func enqueue(_ pixelBuffer: CVPixelBuffer) {
        guard let queue = sink.withLock({ $0.running ? $0.queue : nil }) else { return }
        guard CMSimpleQueueGetCount(queue) < CMSimpleQueueGetCapacity(queue) else { return }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &format) == noErr, let format else { return }
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: now, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer,
                                                       formatDescription: format, sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr, let sample else { return }
        CMSimpleQueueEnqueue(queue, element: Unmanaged.passRetained(sample).toOpaque())
    }
}

// MARK: - Receiver (UDP → decoder → sink)

/// Reassembles and decodes the iMac camera stream (UDP receive thread) into 1080p BGRA frames.
final class CameraStreamReceiver {
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called (throttled) when the stream needs a keyframe.
    var onKeyframeNeeded: (() -> Void)?

    private let assembler = FrameAssembler(staleAfterMs: 100)
    private let gate = FrameGate()
    private var session: VTDecompressionSession?
    private var sessionFormat: CMFormatDescription?
    private let decodeFailed = OSAllocatedUnfairLock(initialState: false)
    private var lastKeyframeRequestNs: UInt64 = 0
    private var lastTickNs: UInt64 = 0
    private var lastFrameNs: UInt64 = 0
    private var streamSession: UInt8 = 0
    private let resetPending = OSAllocatedUnfairLock(initialState: false)
    private(set) var frames = 0

    init() {
        assembler.onFrame = { [unowned self] data, lost in self.decode(data, lost: lost) }
        assembler.onLoss = { [unowned self] in
            self.gate.markLoss()
            self.requestKeyframe()
        }
    }

    /// Any thread: forget the previous stream before the iMac starts a new one. The session byte
    /// alone is not enough – the iMac picks it and starts counting again when its app restarts,
    /// so a matching byte with a stale frame counter would reject every new frame as "late".
    func requestReset() { resetPending.withLock { $0 = true } }

    /// Receive thread.
    func handle(_ buf: UnsafeRawBufferPointer) {
        guard buf.count > DD.chunkHeaderSize, buf[0] == DD.cameraMagic else { return }
        if resetPending.withLock({ let r = $0; $0 = false; return r }) || buf[1] != streamSession {
            streamSession = buf[1]
            reset()
        }
        assembler.ingest(buf, now: hostTimeNs())
    }

    /// Receive thread, regularly.
    func tick(active: Bool) {
        let now = hostTimeNs()
        guard now &- lastTickNs > 20_000_000 else { return }
        lastTickNs = now
        assembler.expireStale(now: now)
        if active && gate.waitingForKeyframe && now &- lastKeyframeRequestNs > 500_000_000 { requestKeyframe() }
    }

    /// Receive thread – new stream (e.g. camera restarted on the iMac).
    func reset() {
        assembler.reset()
        gate.reset()
    }

    var isReceiving: Bool { lastFrameNs != 0 && hostTimeNs() &- lastFrameNs < 1_000_000_000 }

    private func requestKeyframe() {
        let now = hostTimeNs()
        guard now &- lastKeyframeRequestNs > 150_000_000 else { return }
        lastKeyframeRequestNs = now
        onKeyframeNeeded?()
    }

    private func decode(_ data: Data, lost: Bool) {
        if decodeFailed.withLock({ let f = $0; $0 = false; return f }) { gate.markLoss() }
        switch gate.process(data, lossBefore: lost) {
        case .invalid:
            return
        case .needKeyframe:
            requestKeyframe()
        case let .sample(sample, _, _):
            guard let format = CMSampleBufferGetFormatDescription(sample), let session = decoder(for: format) else {
                gate.markLoss()
                requestKeyframe()
                return
            }
            lastFrameNs = hostTimeNs()
            frames += 1
            let onFrame = self.onFrame
            let failed = decodeFailed
            let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample,
                                                           flags: [._EnableAsynchronousDecompression, ._1xRealTimePlayback],
                                                           infoFlagsOut: nil) { status, _, imageBuffer, _, _ in
                if status == noErr, let imageBuffer { onFrame?(imageBuffer) } else if status != noErr { failed.withLock { $0 = true } }
            }
            if status != noErr {
                invalidateDecoder()
                gate.markLoss()
                requestKeyframe()
            }
        }
    }

    private func decoder(for format: CMFormatDescription) -> VTDecompressionSession? {
        if let session, let sessionFormat, CMFormatDescriptionEqual(format, otherFormatDescription: sessionFormat) { return session }
        invalidateDecoder()
        // The decoder scales to exactly the format the camera extension announces.
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: VirtualCameraConfig.width,
            kCVPixelBufferHeightKey: VirtualCameraConfig.height,
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

// MARK: - Extension activation

/// Installs / updates the camera system extension (user approves it once in System Settings).
final class CameraExtensionInstaller: NSObject, OSSystemExtensionRequestDelegate {
    var onStatus: ((String, Bool) -> Void)?   // (message, success)

    func activate() {
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: VirtualCameraConfig.extensionIdentifier,
                                                                 queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        onStatus?("Aktiviere Kamera-Erweiterung…", false)
    }

    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        onStatus?("Bitte in Systemeinstellungen → Allgemein → Anmeldeobjekte & Erweiterungen → Kamera-Erweiterungen „DuoDisplay“ erlauben.", false)
    }

    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed: onStatus?("Kamera-Erweiterung ist aktiv.", true)
        case .willCompleteAfterReboot: onStatus?("Kamera-Erweiterung wird nach einem Neustart aktiv.", false)
        @unknown default: onStatus?("Kamera-Erweiterung: unbekanntes Ergebnis.", false)
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        var message = "Kamera-Erweiterung konnte nicht aktiviert werden: \(error.localizedDescription)"
        if nsError.domain == OSSystemExtensionErrorDomain {
            switch OSSystemExtensionError.Code(rawValue: nsError.code) {
            case .missingEntitlement, .unsupportedParentBundleLocation, .codeSignatureInvalid, .validationFailed:
                message += " – Die App muss mit einem Apple-Developer-Zertifikat und Provisioning-Profilen gebaut und in /Programme liegen (siehe README, „Virtuelle Kamera“)."
            default: break
            }
        }
        onStatus?(message, false)
    }
}
