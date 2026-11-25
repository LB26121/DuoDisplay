import Foundation
import Network
import AVFoundation
import os

/// MacBook side of camera + microphone: watches whether apps use the virtual "iMac-Kamera" /
/// "iMac-Mikrofon", asks the iMac to send them only then, and feeds what arrives into the
/// virtual devices. @Published state is mutated on the main thread.
final class MediaHub: ObservableObject {
    @Published private(set) var cameraInstalled = false
    @Published private(set) var cameraInUse = false
    @Published private(set) var cameraReceiving = false
    @Published private(set) var micInstalled = false
    @Published private(set) var micNeedsUpdate = false
    @Published private(set) var micInUse = false
    @Published private(set) var micReceiving = false
    @Published private(set) var remoteProblem: String?
    @Published private(set) var cameraMessage: String?
    @Published private(set) var micMessage: String?
    @Published private(set) var installingMic = false

    private(set) var port: UInt16 = 0
    private let udp = UDPReceiver()
    private let cameraSink = VirtualCameraSink()
    private let cameraReceiver = CameraStreamReceiver()
    private let micPlayer = AudioPlayer(kind: .microphone, deviceUID: VirtualMic.deviceUID, outputChannels: 1, targetMs: 25)
    private let installer = CameraExtensionInstaller()
    private let send = OSAllocatedUnfairLock<((ControlMessage) -> Void)?>(initialState: nil)
    private let cameraActive = OSAllocatedUnfairLock(initialState: false)
    private var connected = false
    private var feeding = false
    private var micPlaying = false
    private var sentDemand: (camera: Bool, mic: Bool)?
    private var timer: Timer?
    private var udpStarted = false
    private var checkedMicVersion = false

    init() {
        let sink = cameraSink
        let receiver = cameraReceiver
        let player = micPlayer
        let active = cameraActive
        receiver.onFrame = { sink.enqueue($0) }
        receiver.onKeyframeNeeded = { [weak self] in self?.send.withLock { $0 }?(ControlMessage(.cameraKeyframe)) }
        udp.onDatagram = { buf in
            if AudioPacket.isAudio(buf) { player.ingest(buf) } else { receiver.handle(buf) }
        }
        udp.onTick = { receiver.tick(active: active.withLock { $0 }) }
        installer.onStatus = { [weak self] message, _ in self?.cameraMessage = message }
        micPlayer.onError = { [weak self] message in DispatchQueue.main.async { self?.micMessage = message } }
    }

    func start() {
        if !udpStarted {
            do {
                try udp.start()
                port = udp.port
                udpStarted = true
            } catch {
                micMessage = error.localizedDescription
            }
        }
        guard timer == nil else { return }
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    func stop() {
        detach()
        timer?.invalidate()
        timer = nil
    }

    /// Control channel is up; `incoming` opens what the iMac sends (camera, microphone).
    func attach(incoming: MediaOpener, send: @escaping (ControlMessage) -> Void) {
        udp.setOpener(incoming)
        self.send.withLock { $0 = send }
        connected = true
        sentDemand = nil
        remoteProblem = nil
        poll()
    }

    func detach() {
        udp.setOpener(nil)
        send.withLock { $0 = nil }
        connected = false
        sentDemand = nil
        remoteProblem = nil
        apply(camera: false, mic: false)
    }

    func handleStatus(_ text: String?) { remoteProblem = text }

    // MARK: User actions

    func activateCameraExtension() { installer.activate() }

    func installMic() {
        installingMic = true
        micMessage = nil
        VirtualMic.install { [weak self] error in
            guard let self else { return }
            self.installingMic = false
            self.checkedMicVersion = false
            self.micMessage = error ?? "Installiert. Das „iMac-Mikrofon (DuoDisplay)“ steht jetzt allen Apps zur Verfügung."
            self.poll()
        }
    }

    // MARK: Polling (main)

    private func poll() {
        let camera = cameraSink.poll()
        set(\.cameraInstalled, camera.installed)
        set(\.cameraInUse, camera.demanded)

        let micDevice = VirtualMic.device
        if (micDevice != nil) != micInstalled || !checkedMicVersion {
            checkedMicVersion = true   // compares the driver files – only when the device appears
            set(\.micNeedsUpdate, micDevice != nil && VirtualMic.needsUpdate)
        }
        set(\.micInstalled, micDevice != nil)
        set(\.micInUse, micDevice.map { !VirtualMic.otherClients(of: $0).isEmpty } ?? false)

        apply(camera: connected && camera.demanded, mic: connected && micInUse)
        set(\.cameraReceiving, feeding && cameraReceiver.isReceiving)
        set(\.micReceiving, micPlaying && micPlayer.isReceiving)
    }

    private func apply(camera: Bool, mic: Bool) {
        // The sink stops feeding by itself when the extension restarts; start it again below.
        if feeding && !cameraSink.isFeeding { feeding = false }
        if camera && !feeding {
            if MediaPermissions.status(.video) == .notDetermined {
                MediaPermissions.request(.video) { [weak self] _ in self?.poll() }
            }
            feeding = cameraSink.startFeeding()
            if feeding {
                cameraReceiver.requestReset()   // the iMac starts a new stream (frame ids from 1)
            } else {
                cameraMessage = "Die virtuelle Kamera nimmt keine Bilder an (Kamera-Zugriff für DuoDisplay erlaubt?)."
            }
        } else if !camera && feeding {
            cameraSink.stopFeeding()
            feeding = false
        }
        cameraActive.withLock { $0 = feeding }

        if mic && !micPlaying {
            micPlayer.start()
            micPlaying = true
        } else if !mic && micPlaying {
            micPlayer.stop()
            micPlaying = false
        }

        guard connected else { return }
        let demand = (camera: camera && feeding, mic: mic)
        if sentDemand == nil || sentDemand! != demand {
            sentDemand = demand
            var message = ControlMessage(.mediaDemand)
            message.camera = demand.camera
            message.microphone = demand.mic
            send.withLock { $0 }?(message)
        }
    }

    private func set<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<MediaHub, T>, _ value: T) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }
}

/// iMac side: switches camera / microphone on only while the MacBook asks for them.
/// Main thread except `requestKeyframe`.
final class MediaProvider: ObservableObject {
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: "receiver.shareMedia") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "receiver.shareMedia")
            apply()
        }
    }
    @Published private(set) var cameraActive = false
    @Published private(set) var micActive = false
    @Published private(set) var problem: String?
    /// Bumped when a permission answer arrives, so views re-read the status.
    @Published private(set) var permissionTick = 0

    private struct Target {
        let host: NWEndpoint.Host
        let port: UInt16
        let interface: NWInterface?
        let datagramSize: Int
        /// Seals camera and microphone datagrams (iMac → MacBook key of this connection).
        let sealer: MediaSealer
    }

    private let camera = CameraCapture()
    private let mic = MicCapture()
    private var micSender: AudioSender?
    private var target: Target?
    private var send: ((ControlMessage) -> Void)?
    private var wantCamera = false
    private var wantMic = false

    init() {
        camera.onError = { [weak self] message in self?.report(message) }
    }

    func attach(host: NWEndpoint.Host, port: UInt16, interface: NWInterface?, datagramSize: Int,
                sealer: MediaSealer, send: @escaping (ControlMessage) -> Void) {
        target = Target(host: host, port: port, interface: interface, datagramSize: datagramSize, sealer: sealer)
        self.send = send
    }

    func detach() {
        wantCamera = false
        wantMic = false
        apply()
        target = nil
        send = nil
    }

    func handleDemand(camera: Bool, microphone: Bool) {
        wantCamera = camera
        wantMic = microphone
        apply()
    }

    /// Thread-safe.
    func requestKeyframe() { camera.requestKeyframe() }

    func requestPermission(_ type: AVMediaType) {
        MediaPermissions.request(type) { [weak self] _ in
            self?.permissionTick += 1
            self?.apply()
        }
    }

    private func apply() {
        var problems: [String] = []
        let target = self.target

        let cameraOn = enabled && wantCamera && target != nil
        if cameraOn && !camera.isRunning, let target {
            switch MediaPermissions.status(.video) {
            case .authorized:
                do {
                    try camera.start(host: target.host, port: target.port, interface: target.interface,
                                     datagramSize: target.datagramSize, sealer: target.sealer)
                } catch {
                    problems.append(error.localizedDescription)
                }
            case .notDetermined:
                requestPermission(.video)
            default:
                problems.append("Kamera-Zugriff ist auf dem iMac nicht erlaubt.")
            }
        } else if !cameraOn && camera.isRunning {
            camera.stop()
        }

        let micOn = enabled && wantMic && target != nil
        if micOn && !mic.isRunning, let target {
            switch MediaPermissions.status(.audio) {
            case .authorized:
                let sender = AudioSender(host: target.host, port: target.port, kind: .microphone, interface: target.interface,
                                         sealer: target.sealer)
                mic.onAudio = { samples, frames, channels, rate in sender.push(samples, frames: frames, channels: channels, sampleRate: rate) }
                do {
                    try mic.start()
                    micSender = sender
                } catch {
                    sender.cancel()
                    problems.append(error.localizedDescription)
                }
            case .notDetermined:
                requestPermission(.audio)
            default:
                problems.append("Mikrofon-Zugriff ist auf dem iMac nicht erlaubt.")
            }
        } else if !micOn && mic.isRunning {
            mic.stop()
            mic.onAudio = nil
            micSender?.cancel()
            micSender = nil
        }

        if !enabled && (wantCamera || wantMic) {
            problems.append("Kamera und Mikrofon sind auf dem iMac nicht freigegeben.")
        }
        cameraActive = camera.isRunning
        micActive = mic.isRunning
        report(problems.isEmpty ? nil : problems.joined(separator: " "))
    }

    private func report(_ text: String?) {
        guard text != problem else { return }
        problem = text
        var message = ControlMessage(.mediaStatus)
        message.text = text
        send?(message)
    }
}
