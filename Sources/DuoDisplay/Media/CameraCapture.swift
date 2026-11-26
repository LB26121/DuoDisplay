import Foundation
import AVFoundation
import Network

/// iMac side: records the built-in camera (1080p, 30 fps), HEVC-encodes it in hardware and sends
/// it to the MacBook over UDP – the same chunked format as the screen video.
final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    static let fps = 30
    static let bitrateMbps = 12.0

    var onError: ((String) -> Void)?

    private let queue = DispatchQueue(label: "duodisplay.camera.capture", qos: .userInteractive)
    private var session: AVCaptureSession?
    private var encoder: VideoEncoder?        // queue only
    private var encoderSize = (0, 0)          // queue only
    private var sender: UDPVideoSender?       // queue only
    private var observers: [NSObjectProtocol] = []
    private var streamSession: UInt8 = 0      // changes per start so the MacBook resets its reassembly

    var isRunning: Bool { session != nil }

    /// Prefers the built-in camera over Continuity Camera / external ones.
    static func preferredDevice() -> AVCaptureDevice? {
        let builtIn = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera],
                                                       mediaType: .video, position: .unspecified).devices
        return builtIn.first ?? AVCaptureDevice.default(for: .video)
    }

    func start(host: NWEndpoint.Host, port: UInt16, interface: NWInterface?, datagramSize: Int, sealer: MediaSealer) throws {
        stop()
        guard let device = Self.preferredDevice() else { throw DDError("No camera found") }
        let session = AVCaptureSession()
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw DDError("Camera cannot be used") }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        output.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(output) else { throw DDError("Cannot read camera frames") }
        session.addOutput(output)
        session.commitConfiguration()

        if (try? device.lockForConfiguration()) != nil {
            let duration = CMTime(value: 1, timescale: CMTimeScale(Self.fps))
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameDuration <= duration && $0.maxFrameDuration >= duration }) {
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
            }
            device.unlockForConfiguration()
        }

        streamSession = streamSession == UInt8.max ? 1 : streamSession + 1
        let udp = UDPVideoSender(host: host, port: port, session: streamSession, datagramSize: datagramSize,
                                 interface: interface, sealer: sealer, magic: DD.cameraMagic)
        queue.sync {
            sender = udp
            encoder = nil
        }
        observers = [NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.onError?("Camera: \(error?.localizedDescription ?? "error")")
        }]
        self.session = session
        queue.async { session.startRunning() }
    }

    func stop() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        guard let session else { return }
        self.session = nil
        queue.async { [self] in
            session.stopRunning()
            encoder?.invalidate()
            encoder = nil
            sender?.cancel()
            sender = nil
        }
    }

    /// Thread-safe.
    func requestKeyframe() {
        queue.async { self.encoder?.requestKeyframe() }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let sender, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let size = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        if encoder == nil || encoderSize != size {
            encoder?.invalidate()
            do {
                let encoder = try VideoEncoder(codec: .hevc, width: size.0, height: size.1, fps: Self.fps,
                                               bitrateMbps: Self.bitrateMbps, lowLatencyRateControl: false)
                encoder.onEncoded = { payload, _, _, _ in sender.send(payload) }
                self.encoder = encoder
                encoderSize = size
            } catch {
                DispatchQueue.main.async { self.onError?(error.localizedDescription) }
                return
            }
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        encoder?.encode(pixelBuffer, captureNs: hostTimeNs(of: pts))
    }
}
