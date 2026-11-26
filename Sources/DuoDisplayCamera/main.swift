// DuoDisplay camera extension (Core Media I/O system extension, runs in its own sandboxed process).
//
// Publishes one camera, "iMac Camera (DuoDisplay)", with two streams:
//  • source – what FaceTime, Zoom, Teams … read
//  • sink   – the DuoDisplay app pushes the decoded iMac camera frames in here
// Every frame from the sink is forwarded to the source unchanged. While no frames arrive
// (iMac not connected yet) the source sends black frames so apps do not stall.
//
// The sink stream carries the custom property 'ddon' ("1" / "0"): whether any app is reading
// the camera right now. The DuoDisplay app polls it and only then switches the iMac camera on.

import Foundation
import CoreMediaIO
import CoreMedia
import CoreVideo

enum CameraConfig {
    static let width: Int32 = 1920
    static let height: Int32 = 1080
    static let fps: Int32 = 30
    static let deviceUID = "DuoDisplay-iMacCamera"   // = kCMIODevicePropertyDeviceUID seen by the app
    static let deviceUUID = UUID(uuidString: "36E3083A-00E5-4A50-BD2D-AC2D6EC52225")!
    static let sourceUUID = UUID(uuidString: "84663A03-F683-43E0-B67B-A8A1DB97C804")!
    static let sinkUUID = UUID(uuidString: "89236444-48B6-4966-AF84-B67E105897C0")!
    static let demandProperty = CMIOExtensionProperty(rawValue: "4cc_ddon_glob_0000")
}

final class DeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private var source: StreamSource!
    private var sink: StreamSource!

    private let queue = DispatchQueue(label: "duodisplay.camera.extension", qos: .userInteractive)
    private let format: CMVideoFormatDescription
    private let blackPool: CVPixelBufferPool
    private var timer: DispatchSourceTimer?

    // queue only
    private var sourceRunning = false
    private var sinkRunning = false
    private var sinkClient: CMIOExtensionClient?
    private var lastSinkFrameNs: UInt64 = 0

    init(localizedName: String) {
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA,
                                       width: CameraConfig.width, height: CameraConfig.height,
                                       extensions: nil, formatDescriptionOut: &fmt)
        format = fmt!
        var pool: CVPixelBufferPool?
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: CameraConfig.width,
            kCVPixelBufferHeightKey: CameraConfig.height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        blackPool = pool!
        super.init()

        device = CMIOExtensionDevice(localizedName: localizedName, deviceID: CameraConfig.deviceUUID,
                                     legacyDeviceID: CameraConfig.deviceUID, source: self)
        let frameDuration = CMTime(value: 1, timescale: CameraConfig.fps)
        let streamFormat = CMIOExtensionStreamFormat(formatDescription: format, maxFrameDuration: frameDuration,
                                                     minFrameDuration: frameDuration, validFrameDurations: nil)
        source = StreamSource(name: "iMac Camera", id: CameraConfig.sourceUUID, format: streamFormat, sink: false, owner: self)
        sink = StreamSource(name: "iMac Camera Input", id: CameraConfig.sinkUUID, format: streamFormat, sink: true, owner: self)
        do {
            try device.addStream(source.stream)
            try device.addStream(sink.stream)
        } catch {
            fatalError("Could not create streams: \(error)")
        }
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.deviceTransportType, .deviceModel] }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let p = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) { p.transportType = 0x7669_7274 }   // 'virt'
        if properties.contains(.deviceModel) { p.model = "DuoDisplay iMac Camera" }
        return p
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    // MARK: Stream state (called by StreamSource)

    var isDemanded: Bool { queue.sync { sourceRunning } }

    func setSinkClient(_ client: CMIOExtensionClient) { queue.sync { sinkClient = client } }

    func setRunning(sink isSink: Bool, _ running: Bool) {
        queue.sync {
            if isSink { sinkRunning = running } else { sourceRunning = running }
            updateTimer()
        }
        if !isSink {
            sink.stream.notifyPropertiesChanged(
                [CameraConfig.demandProperty: CMIOExtensionPropertyState(value: (running ? "1" : "0") as NSString as AnyObject)])
        }
    }

    /// queue: 60 Hz while anything runs – pulls frames from the sink, fills gaps with black.
    private func updateTimer() {
        let needed = sourceRunning || sinkRunning
        if needed && timer == nil {
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            t.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / 60), leeway: .milliseconds(1))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            timer = t
        } else if !needed, let t = timer {
            t.cancel()
            timer = nil
        }
    }

    private var lastBlackNs: UInt64 = 0

    private func tick() {
        let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if sinkRunning, let client = sinkClient { consume(from: client) }
        // No frames from the iMac for a while: keep the apps fed with black at 30 fps.
        if sourceRunning, now &- lastSinkFrameNs > 300_000_000, now &- lastBlackNs >= 33_000_000 {
            lastBlackNs = now
            sendBlack(now: now)
        }
    }

    private func consume(from client: CMIOExtensionClient) {
        sink.stream.consumeSampleBuffer(from: client) { [weak self] buffer, sequence, _, hasMore, _ in
            guard let self, let buffer else { return }
            self.queue.async {
                let now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                self.lastSinkFrameNs = now
                if self.sourceRunning {
                    self.source.stream.send(buffer, discontinuity: [], hostTimeInNanoseconds: now)
                }
                self.sink.stream.notifyScheduledOutputChanged(
                    CMIOExtensionScheduledOutput(sequenceNumber: sequence, hostTimeInNanoseconds: now))
                if hasMore, self.sinkRunning, let client = self.sinkClient { self.consume(from: client) }
            }
        }
    }

    /// One opaque black image, created once and re-sent (consumers only read it).
    private lazy var blackFrame: CVPixelBuffer? = {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, blackPool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let base = CVPixelBufferGetBaseAddress(pixelBuffer) {
            let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
            memset(base, 0, rowBytes * CVPixelBufferGetHeight(pixelBuffer))
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<Int(CameraConfig.height) {
                let row = bytes + y * rowBytes
                for x in 0..<Int(CameraConfig.width) { row[x * 4 + 3] = 255 }
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        return pixelBuffer
    }()

    private func sendBlack(now: UInt64) {
        guard let pixelBuffer = blackFrame else { return }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CameraConfig.fps),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(now), timescale: 1_000_000_000),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, dataReady: true,
                                           makeDataReadyCallback: nil, refcon: nil, formatDescription: format,
                                           sampleTiming: &timing, sampleBufferOut: &sample)
        if let sample { source.stream.send(sample, discontinuity: [], hostTimeInNanoseconds: now) }
    }
}

final class StreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let format: CMIOExtensionStreamFormat
    private let isSink: Bool
    private unowned let owner: DeviceSource

    init(name: String, id: UUID, format: CMIOExtensionStreamFormat, sink: Bool, owner: DeviceSource) {
        self.format = format
        self.isSink = sink
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: name, streamID: id, direction: sink ? .sink : .source,
                                     clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        var p: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if isSink {
            p.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                         .streamSinkBufferUnderrunCount, .streamSinkEndOfData, CameraConfig.demandProperty])
        }
        return p
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let p = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { p.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { p.frameDuration = CMTime(value: 1, timescale: CameraConfig.fps) }
        if properties.contains(.streamSinkBufferQueueSize) { p.sinkBufferQueueSize = 3 }
        if properties.contains(.streamSinkBuffersRequiredForStartup) { p.sinkBuffersRequiredForStartup = 1 }
        if isSink && properties.contains(CameraConfig.demandProperty) {
            p.setPropertyState(CMIOExtensionPropertyState(value: (owner.isDemanded ? "1" : "0") as NSString),
                               forProperty: CameraConfig.demandProperty)
        }
        return p
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        if isSink { owner.setSinkClient(client) }
        return true
    }

    func startStream() throws { owner.setRunning(sink: isSink, true) }
    func stopStream() throws { owner.setRunning(sink: isSink, false) }
}

final class ProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: DeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = DeviceSource(localizedName: "iMac Camera (DuoDisplay)")
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("Could not create camera: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        let p = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) { p.manufacturer = "DuoDisplay" }
        return p
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

let providerSource = ProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
