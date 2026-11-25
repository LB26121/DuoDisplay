import Foundation
import Network
import AppKit
import VideoToolbox
import os

/// Receiver role (the iMac): stays paired with the sender and switches between
///  • `.display` – full-screen stream of the sender's extra screen; all local input is forwarded
///  • `.local`   – normal standalone use; pushing the pointer over the edge facing the MacBook hands
///                 keyboard + pointer to the MacBook until it comes back (EdgeSwitch.swift).
///                 ⌃⌥⌘P shows the MacBook's main screen as picture-in-picture; moving the pointer
///                 into the picture hands keyboard + pointer over as well (PiPWindow.swift).
/// @Published state is mutated on the main thread.
final class ReceiverService: ObservableObject {
    @Published private(set) var peerName: String? {
        didSet { connectedActivity.set(peerName != nil) }
    }
    private let connectedActivity = LatencyActivity(reason: "DuoDisplay ist mit dem MacBook verbunden")
    @Published private(set) var mode: LinkMode = .local
    @Published private(set) var status = "Starte…"
    @Published private(set) var statsLine = ""
    @Published private(set) var thunderboltLinks: [NetLink] = []
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var inputForwarding = false
    /// "Normal nutzen": keyboard and pointer of this Mac currently control the MacBook.
    @Published private(set) var edgeActive = false
    /// Edge of this Mac's screens that leads to the MacBook (nil = crossing switched off there).
    @Published private(set) var peerEdge: ScreenEdge? {
        didSet { peerEdgeBox.withLock { $0 = peerEdge } }
    }
    /// Copy of `peerEdge` for the control queue (pointer coming back from the MacBook).
    private let peerEdgeBox = OSAllocatedUnfairLock<ScreenEdge?>(initialState: nil)
    @Published var showStats = false
    /// Wait for the iMac's refresh before showing a frame: no tear lines while scrolling,
    /// Ø ~8 ms more delay at 60 Hz.
    @Published var vsync: Bool = UserDefaults.standard.object(forKey: "receiver.vsync") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(vsync, forKey: "receiver.vsync")
            renderer.presenter.vsync = vsync
        }
    }
    /// The MacBook this iMac is paired with – the only one that may connect.
    @Published private(set) var pairedName: String?
    /// ⌃⌥⌘P: show the MacBook's main screen as picture-in-picture in "Normal nutzen" (remembered).
    @Published private(set) var pipWanted: Bool = UserDefaults.standard.bool(forKey: "receiver.pip") {
        didSet { UserDefaults.standard.set(pipWanted, forKey: "receiver.pip") }
    }
    /// Picture-in-picture shows an extra screen of the MacBook instead of mirroring its main screen
    /// (remembered). Switchable while the picture is open (title bar of the window).
    @Published private(set) var pipExtended: Bool = UserDefaults.standard.bool(forKey: "receiver.pipExtended") {
        didSet { UserDefaults.standard.set(pipExtended, forKey: "receiver.pipExtended") }
    }
    /// The picture-in-picture window is on screen.
    @Published private(set) var pipShowing = false
    /// Why the picture-in-picture could not be shown (nil = fine).
    @Published private(set) var pipProblem: String?
    /// pipStart sent to the MacBook, no pipStop since.
    private var pipRequested = false
    /// The MacBook can take input through the picture (it has the Accessibility permission).
    private var pipControllable = false
    /// Size of the MacBook's main screen in points (for the pointer speed in the picture). Any thread.
    private let pipMacPoints = OSAllocatedUnfairLock(initialState: CGSize.zero)
    /// The window as it was when the current session started through it (nil = no session, or one
    /// over the screen edge). Any thread.
    private let pipSessionBox = OSAllocatedUnfairLock<PiPTarget?>(initialState: nil)

    let renderer = VideoRenderer()
    let name = localComputerName()
    let pairingPrompt = PairingPrompt()
    /// The pending connection whose code is on screen right now.
    private var pairingChannel: ControlChannel?
    /// After a declined pairing, new attempts are refused for a moment (no prompt spam).
    private var pairingBlockedUntil = Date.distantPast
    private var pairingObserver: NSObjectProtocol?
    /// Camera + microphone for the MacBook (only while an app there uses them).
    let media = MediaProvider()
    /// MacBook sound in display mode.
    private let systemAudio = AudioPlayer(kind: .systemAudio, outputChannels: 2, targetMs: 20)
    /// The MacBook says its sound plays here (audioRoute): in display mode the volume keys stay here.
    private var peerAudioHere = false

    private lazy var pipeline = ReceiverPipeline(renderer: renderer)
    private lazy var streamWindow = StreamWindowController(presenter: renderer.presenter)
    private lazy var pipWindow: PiPWindowController = {
        let window = PiPWindowController(presenter: renderer.presenter)
        window.onClose = { [weak self] in self?.togglePiP() }
        window.onExtendedChange = { [weak self] in self?.setPiPExtended($0) }
        window.onGeometryChange = { [weak self] in self?.updateEdgeWatcher() }
        return window
    }()
    private let input = InputCapture()
    private let edgeWatcher = EdgeWatcher()
    /// Set on the edge watcher's tap thread the moment the pointer crosses, cleared on main.
    private let edgeBox = OSAllocatedUnfairLock(initialState: false)
    private var lastPongNs: UInt64 = 0         // controlQueue only
    private let udp = UDPReceiver()
    private let controlQueue = DispatchQueue(label: "duodisplay.receiver.control", qos: .userInteractive)
    private var listener: NWListener?
    /// Also read on the event-tap threads (input forwarding, edge crossing), hence the lock.
    private let controlBox = OSAllocatedUnfairLock<ControlChannel?>(initialState: nil)
    private var control: ControlChannel? {
        get { controlBox.withLock { $0 } }
        set { controlBox.withLock { $0 = newValue } }
    }
    /// Connections that have not authenticated yet; they replace the current session only then.
    private var pendingChannels: [ControlChannel] = []
    private var connection: NWConnection?
    /// Seals camera and microphone for the current connection (nil while there is none). One
    /// instance per connection: a second one with the same key would reuse its counters (nonces).
    private var mediaSealer: MediaSealer?
    private var sessionCounter: UInt8 = 0
    private var pingTimer: DispatchSourceTimer?
    private var clock = ClockSync()          // controlQueue only
    private var keyMonitor: Any?
    private var activity: NSObjectProtocol?
    private var pollTimer: Timer?
    private var cursorHidden = false
    private var started = false
    private var udpStarted = false

    var isConnected: Bool { peerName != nil }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        renderer.presenter.vsync = vsync
        pairedName = PairingStore.shared.peer?.name
        if pairingObserver == nil {
            pairingObserver = NotificationCenter.default.addObserver(forName: PairingStore.didChange, object: nil,
                                                                     queue: .main) { [weak self] _ in
                self?.pairedName = PairingStore.shared.peer?.name
            }
        }
        if !udpStarted {
            do {
                try udp.start()
                udpStarted = true
            } catch {
                status = error.localizedDescription
                return
            }
            let pipeline = self.pipeline
            let audio = systemAudio
            udp.onDatagram = { buf in
                if AudioPacket.isAudio(buf) { audio.ingest(buf) } else { pipeline.handle(buf) }
            }
            udp.onTick = { pipeline.tick() }
            pipeline.onStats = { [weak self] stats in
                DispatchQueue.main.async { self?.statsLine = stats.line }
            }
        }
        input.onEvent = { [weak self] data in self?.control?.send(.inputEvent, data) }
        input.onHotkey = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                // Emergency exit while controlling the MacBook: take keyboard and pointer back.
                if self.edgeActive || self.edgeBox.withLock({ $0 }) {
                    self.endEdgeSession(fraction: nil, notifyPeer: true)
                } else {
                    self.requestToggle()
                }
            }
        }
        input.onPiPHotkey = { [weak self] in
            DispatchQueue.main.async { self?.togglePiP() }
        }
        edgeWatcher.onPiPEnter = { [weak self] n, target in self?.beginEdgeSession(fraction: 0, pip: (n, target)) }
        edgeWatcher.onCross = { [weak self] fraction in self?.beginEdgeSession(fraction: fraction) }
        installInputCaptureIfPossible()
        startListener()
        refreshPeriodic()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPeriodic() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Only reached when input forwarding is unavailable (no Accessibility permission).
            guard let self, self.mode == .display else { return event }
            if event.keyCode == 1 { self.showStats.toggle(); return nil }   // S
            return event
        }
    }

    func stop() {
        guard started else { return }
        started = false
        endSession()
        pendingChannels.forEach { dropPending($0) }
        listener?.cancel()
        listener = nil
        pollTimer?.invalidate()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func refreshPeriodic() {
        let links = NetInfo.thunderboltLinks()
        if links != thunderboltLinks { thunderboltLinks = links }
        let granted = Permissions.accessibilityGranted
        if granted != accessibilityGranted { accessibilityGranted = granted }
        if granted && !input.isInstalled { installInputCaptureIfPossible() }
    }

    private func installInputCaptureIfPossible() {
        guard Permissions.accessibilityGranted else { return }
        if input.install() {
            inputForwarding = true
            if mode == .display { activateInputCapture(true) }
        }
        if edgeWatcher.install() { updateEdgeWatcher() }
    }

    private func startListener() {
        do {
            let listener = try NWListener(using: Net.tcpParameters(requiredInterface: nil))
            listener.service = NWListener.Service(name: name, type: DD.bonjourType)
            listener.newConnectionHandler = { [weak self] connection in
                DispatchQueue.main.async { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch state {
                    case .ready:
                        if !self.isConnected { self.status = "Bereit – warte auf das MacBook" }
                    case .failed(let error):
                        self.status = "Netzwerkfehler: \(error.localizedDescription)"
                        self.listener?.cancel()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.started { self.startListener() } }
                    default:
                        break
                    }
                }
            }
            listener.start(queue: controlQueue)
            self.listener = listener
        } catch {
            status = "Netzwerkfehler: \(error.localizedDescription)"
        }
    }

    // MARK: Connection

    /// The current session stays until the newcomer has proven it is the paired MacBook (a
    /// reconnecting MacBook does so right away) – a stray or foreign connection never takes over.
    private func accept(_ connection: NWConnection) {
        let channel = ControlChannel(connection: connection, queue: controlQueue)
        let handshake = ServerHandshake(channel: channel, ownName: name)
        handshake.onEvent = { [weak self, weak channel] event in
            DispatchQueue.main.async {
                guard let self, let channel else { return }
                self.handleHandshake(event, handshake: handshake, channel: channel)
            }
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self, let channel else { return }
            // Until the MacBook has authenticated itself, only the handshake is processed.
            guard handshake.isAuthenticated else { return handshake.handle(message) }
            switch message.kind {
            case .pong:
                guard self.control === channel else { return }
                self.handlePong(message)
            case .cameraKeyframe:
                guard self.control === channel else { return }
                self.media.requestKeyframe()
            case .edgeLeave:
                guard self.control === channel else { return }
                let pipAt = message.pipX.flatMap { x in message.pipY.map { CGPoint(x: x, y: $0) } }
                self.edgeReturned(fraction: message.fraction, pipAt: pipAt, pipSide: message.pipSide,
                                  eventTime: message.eventTime, peerInfo: message.text)
            default:
                DispatchQueue.main.async { self.handle(message, from: channel) }
            }
        }
        channel.onBinary = { [weak self, weak channel] kind, data in
            guard handshake.isAuthenticated, kind == .cursorPosition, data.count >= 9,
                  let self, let channel, self.control === channel else { return }
            let (x, y, visible) = data.withUnsafeBytes {
                ($0.readLE(0, as: UInt32.self), $0.readLE(4, as: UInt32.self), $0[8] != 0)
            }
            self.renderer.presenter.updateCursor(x: CGFloat(Float(bitPattern: x)), y: CGFloat(Float(bitPattern: y)), visible: visible)
        }
        channel.onClose = { [weak self, weak channel] _ in
            DispatchQueue.main.async {
                guard let self, let channel else { return }
                if self.control === channel {
                    self.endSession()
                } else {
                    self.dropPending(channel)
                }
            }
        }
        pendingChannels.append(channel)
        channel.start()
        expireIfIdle(channel)
    }

    /// A peer that neither authenticates nor pairs within 10 s is not the MacBook.
    private func expireIfIdle(_ channel: ControlChannel) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self, weak channel] in
            guard let self, let channel, self.pendingChannels.contains(where: { $0 === channel }) else { return }
            if self.pairingChannel === channel {
                self.expireIfIdle(channel)   // the prompt has its own 2-minute timeout
            } else {
                self.dropPending(channel)
            }
        }
    }

    private func dropPending(_ channel: ControlChannel, closeAfter delay: TimeInterval = 0) {
        pendingChannels.removeAll { $0 === channel }
        if pairingChannel === channel {
            pairingChannel = nil
            pairingPrompt.close()
        }
        // A short delay lets a final pairCancel / authFailed reach the MacBook.
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { channel.close() }
    }

    /// Main thread: result of the handshake on a pending connection.
    private func handleHandshake(_ event: ServerHandshake.Event, handshake: ServerHandshake, channel: ControlChannel) {
        guard pendingChannels.contains(where: { $0 === channel }) else { return }
        switch event {
        case .authenticated(let hello, _, let keys):
            if pairingChannel === channel {
                pairingChannel = nil
                pairingPrompt.close()
            }
            promote(channel, hello: hello, media: keys)

        case .pairingCode(let code, let peer):
            let refusal: String?
            if mode == .display {
                refusal = "„\(name)“ zeigt gerade einen Bildschirm an – zum Koppeln dort erst „Normal nutzen“ wählen."
            } else if pairingChannel != nil {
                refusal = "Auf „\(name)“ läuft gerade schon eine Kopplung."
            } else if Date() < pairingBlockedUntil {
                refusal = "Bitte ein paar Sekunden warten und erneut verbinden."
            } else {
                refusal = nil
            }
            if let refusal {
                controlQueue.async { handshake.cancelPairing(refusal) }
                return
            }
            pairingChannel = channel
            // Only reached while this Mac is not paired (ServerHandshake refuses otherwise).
            let viaThunderbolt = channel.connection.currentPath?.availableInterfaces.first
                .map { NetInfo.isThunderbolt($0.name, tbNames: NetInfo.thunderboltNames()) } ?? false
            pairingPrompt.show(
                code: code, peerName: peer.name,
                note: viaThunderbolt ? nil : PairingPrompt.notThunderboltNote(channel.connection),
                onConfirm: { [weak self] in self?.controlQueue.async { handshake.confirmPairing() } },
                onCancel: { [weak self] in
                    self?.pairingBlockedUntil = Date() + 10
                    self?.controlQueue.async { handshake.cancelPairing("Die Kopplung wurde am iMac abgelehnt.") }
                })

        case .paired:
            if pairingChannel === channel {
                pairingChannel = nil
                pairingPrompt.close()
            }
            // authChallenge → authResponse → .authenticated follows.

        case .failed(let text):
            ddLog.notice("Verbindung abgelehnt: \(text, privacy: .public)")
            if pairingChannel === channel { pairingBlockedUntil = Date() + 10 }
            if !isConnected { status = text }
            dropPending(channel, closeAfter: 0.5)
        }
    }

    /// Forgets the paired MacBook; it has to pair again before it can connect.
    func forgetPairing() {
        PairingStore.shared.forget()
        endSession()
    }

    /// Main thread: the new connection authenticated – it replaces the current session.
    private func promote(_ channel: ControlChannel, hello: ControlMessage, media keys: MediaKeys) {
        guard let index = pendingChannels.firstIndex(where: { $0 === channel }) else { return }
        pendingChannels.remove(at: index)
        endSession()
        control = channel
        connection = channel.connection
        // From now on only what this MacBook seals reaches the screen and the speakers.
        udp.setOpener(MediaOpener(key: keys.toReceiver))
        mediaSealer = MediaSealer(key: keys.toSender)
        handle(hello, from: channel)
    }

    private func handle(_ message: ControlMessage, from channel: ControlChannel) {
        guard control === channel else { return }
        switch message.kind {
        case .hello:
            peerName = message.name ?? "Mac"
            status = "Verbunden mit \(peerName!)"
            startPing(channel)
            if let port = message.udpPort, let connection, let mediaSealer,
               case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint {
                let interface = connection.currentPath?.availableInterfaces.first
                let mtu = interface.flatMap { NetInfo.mtu(of: $0.name) } ?? 1500
                media.attach(host: host, port: port, interface: interface,
                             datagramSize: max(DD.minDatagramSize, min(mtu - 64, DD.maxDatagramSize)),
                             sealer: mediaSealer) { [weak channel] in
                    channel?.send($0)
                }
            }
        case .audioRoute:
            peerAudioHere = message.audio ?? false
            updateVolumeKeys()
        case .mediaDemand:
            media.handleDemand(camera: message.camera ?? false, microphone: message.microphone ?? false)
        case .edgeConfig:
            peerEdge = message.edge
            // A session through the picture-in-picture window does not depend on the screen edge
            // (the MacBook ends it itself when it loses the Accessibility permission).
            if peerEdge == nil, pipSessionBox.withLock({ $0 }) == nil { endEdgeSession(fraction: nil, notifyPeer: false) }
            updateEdgeWatcher()
        case .setMode:
            if message.mode == .display {
                enterDisplay(localCursor: message.localCursor ?? false)
            } else {
                enterLocal()
                syncPiP()   // also right after (re)connecting – the MacBook always starts with setMode
            }
        case .pipState:
            guard pipRequested else { return }
            // Answer to a request from before switching between mirrored and extended: the next one follows.
            if let extended = message.pipExtended, extended != pipExtended { return }
            if message.pip == true, let w = message.pointWidth, let h = message.pointHeight, w > 0, h > 0 {
                let size = CGSize(width: w, height: h)
                let previous = pipMacPoints.withLock { points -> CGSize in let old = points; points = size; return old }
                pipControllable = message.pipControl ?? false
                if pipExtended && message.pipExtended == nil {
                    pipProblem = "Das MacBook kann nur spiegeln – dort DuoDisplay aktualisieren, dann geht auch „Erweitert“."
                } else {
                    pipProblem = pipControllable ? nil
                        : "Steuern über das Bild geht erst, wenn DuoDisplay auf dem MacBook die Bedienungshilfen-Freigabe hat."
                }
                // Sent again when only the permission changed: the window stays as it is then.
                if !pipShowing || previous != size {
                    pipWindow.show(contentPoints: size, localCursor: message.localCursor ?? false)
                }
                pipShowing = true
                ddLog.notice("Bild-in-Bild: \(w)×\(h) pt, steuerbar \(self.pipControllable)")
                updateEdgeWatcher()
            } else {
                // Failed on the MacBook (e.g. no screen recording permission): don't retry on every connect.
                pipProblem = message.text ?? "Das MacBook konnte sein Bild nicht senden."
                pipWanted = false
                stopPiP(notifyPeer: false)
            }
        case .pipToggle:
            togglePiP()
        case .cursorImage:
            guard let png = message.png, let w = message.cursorWidth, let h = message.cursorHeight,
                  let rep = NSBitmapImageRep(data: png), let image = rep.cgImage else { return }
            renderer.presenter.setCursorImage(image, sizePoints: CGSize(width: w, height: h),
                                        hotspot: CGPoint(x: message.hotspotX ?? 0, y: message.hotspotY ?? 0))
        case .stats:
            // The MacBook's side of the stream (resolution, Hz, encoder, capture delay).
            guard mode == .display, let text = message.text else { return }
            ddLog.notice("MacBook: \(text, privacy: .public)")
        default:
            break
        }
    }

    /// ⌃⌥⌘D on this Mac, or the menu / button.
    func requestToggle() {
        guard let control else { return }
        endEdgeSession(fraction: nil, notifyPeer: true)
        var message = ControlMessage(.requestMode)
        if mode == .display {
            // Leave immediately – never wait for the network to give the user their Mac back.
            enterLocal()
            message.mode = .local
        } else {
            message.mode = .display
        }
        control.send(message)
    }

    private func endSession() {
        peerAudioHere = false
        updateVolumeKeys()
        endEdgeSession(fraction: nil, notifyPeer: false)
        stopPiP(notifyPeer: false)
        peerEdge = nil
        enterLocal()
        media.detach()
        udp.setOpener(nil)
        mediaSealer = nil
        let channel = control
        control = nil
        connection = nil
        channel?.close()
        pingTimer?.cancel()
        pingTimer = nil
        if peerName != nil {
            peerName = nil
            status = "Bereit – warte auf das MacBook"
        }
    }

    // MARK: Modes

    private func enterDisplay(localCursor: Bool) {
        guard let control, let screen = NSScreen.screens.first else { return }

        let scale = screen.backingScaleFactor
        let topInset = screen.safeAreaInsets.top          // notch on MacBooks, 0 on an iMac
        let pointW = Int(screen.frame.width)
        let pointH = Int(screen.frame.height - topInset)
        sessionCounter = sessionCounter == UInt8.max ? 1 : sessionCounter + 1

        var info = ControlMessage(.displayInfo)
        info.name = name
        info.pointWidth = pointW
        info.pointHeight = pointH
        info.pixelWidth = Int((Double(pointW) * scale).rounded()) & ~1
        info.pixelHeight = Int((Double(pointH) * scale).rounded()) & ~1
        info.refreshRate = screen.maximumFramesPerSecond
        info.udpPort = udp.port
        info.session = sessionCounter
        info.mtu = connection?.currentPath?.availableInterfaces.first.flatMap { NetInfo.mtu(of: $0.name) } ?? 1500
        info.proRes = VTIsHardwareDecodeSupported(VideoCodec.prores.cmCodecType)

        stopPiP(notifyPeer: false)   // the MacBook stops that stream itself; pipWanted stays for later
        ddLog.notice("Bildschirm-Modus: Sitzung \(self.sessionCounter), Zeiger lokal \(localCursor), schon aktiv \(self.mode == .display), \(pointW)×\(pointH) pt")
        pipeline.activate(session: sessionCounter) { [weak control] message in control?.send(message) }
        control.send(info)

        // Also when already showing: the sender restarts the stream after a settings change
        // (e.g. "Mauszeiger lokal zeichnen"), so the presenter must pick up the new pointer mode.
        streamWindow.show(on: screen, contentPoints: CGSize(width: pointW, height: pointH),
                          topInset: topInset, localCursor: localCursor)
        if mode != .display {
            endEdgeSession(fraction: nil, notifyPeer: false)
            statsLine = ""
            NSApp.activate(ignoringOtherApps: true)
            activateInputCapture(true)
            systemAudio.start()
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                reason: "DuoDisplay zeigt einen Bildschirm an")
            mode = .display
            updateEdgeWatcher()
        }
        updateVolumeKeys()
    }

    private func enterLocal() {
        guard mode == .display else { return }
        ddLog.notice("Normal nutzen")
        activateInputCapture(false)
        systemAudio.stop()
        pipeline.deactivate()
        renderer.clear()
        streamWindow.hide()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
        mode = .local
        updateEdgeWatcher()
        updateVolumeKeys()
        NSApp.hide(nil)   // give focus back to whatever was in front before
    }

    // MARK: Picture-in-picture ("Normal nutzen", ⌃⌥⌘P)

    /// ⌃⌥⌘P on either Mac, the menu or the window's close button. In display mode it switches to
    /// "Normal nutzen" with the picture-in-picture open.
    func togglePiP() {
        // The picture is never on screen in display mode: there ⌃⌥⌘P always means "Normal nutzen"
        // with the picture open – also when it is still wanted from before the display mode.
        if mode == .display && isConnected {
            pipWanted = true
            pipProblem = nil
            requestToggle()   // the MacBook answers with setMode(.local) → syncPiP
            return
        }
        if pipWanted {
            pipWanted = false
            syncPiP()
            return
        }
        pipWanted = true
        pipProblem = nil
        guard isConnected else { return }   // opens as soon as the MacBook is connected
        syncPiP()
    }

    /// Main thread: mirrored (false) or extended (true) picture – window title bar or DuoDisplay window.
    /// An open picture switches right away: the MacBook then streams the other screen.
    func setPiPExtended(_ extended: Bool) {
        guard extended != pipExtended else { return }
        pipExtended = extended
        pipWindow.setExtended(extended)
        guard pipRequested else { return }
        // Input back here first – the screen the MacBook pointer is kept on changes.
        if pipSessionBox.withLock({ $0 }) != nil { endEdgeSession(fraction: nil, notifyPeer: true) }
        ddLog.notice("Bild-in-Bild: \(extended ? "erweitert" : "gespiegelt", privacy: .public)")
        startPiP()   // pipStart again; the window stays open until pipState arrives
    }

    /// Main thread: opens or closes the picture-in-picture to match what is wanted and possible.
    private func syncPiP() {
        let want = pipWanted && isConnected && control != nil && mode == .local
        if want && !pipRequested {
            startPiP()
        } else if !want && pipRequested {
            stopPiP(notifyPeer: true)
        }
    }

    private func startPiP() {
        guard let control, let screen = NSScreen.screens.first else { return }
        sessionCounter = sessionCounter == UInt8.max ? 1 : sessionCounter + 1
        pipRequested = true
        var request = ControlMessage(.pipStart)
        request.udpPort = udp.port
        request.session = sessionCounter
        request.refreshRate = screen.maximumFramesPerSecond
        request.mtu = connection?.currentPath?.availableInterfaces.first.flatMap { NetInfo.mtu(of: $0.name) } ?? 1500
        request.proRes = VTIsHardwareDecodeSupported(VideoCodec.prores.cmCodecType)
        request.pipExtended = pipExtended
        pipWindow.setExtended(pipExtended)
        ddLog.notice("Bild-in-Bild angefordert: Sitzung \(self.sessionCounter), \(self.pipExtended ? "erweitert" : "gespiegelt", privacy: .public)")
        pipeline.activate(session: sessionCounter) { [weak control] message in control?.send(message) }
        control.send(request)
        // The window opens once the MacBook answers with pipState (its screen size).
    }

    /// Main thread. Ends a session through the picture first (input back here).
    private func stopPiP(notifyPeer: Bool) {
        guard pipRequested || pipShowing else { return }
        if pipSessionBox.withLock({ $0 }) != nil { endEdgeSession(fraction: nil, notifyPeer: true) }
        ddLog.notice("Bild-in-Bild geschlossen")
        pipRequested = false
        pipShowing = false
        pipControllable = false
        pipeline.deactivate()
        pipWindow.hide()
        if notifyPeer { control?.send(ControlMessage(.pipStop)) }
        updateEdgeWatcher()
    }

    // MARK: Edge switching ("Normal nutzen")

    /// Watch the edge only while paired, in "Normal nutzen" and not already on the MacBook.
    private func updateEdgeWatcher() {
        let watch = isConnected && mode == .local && !edgeActive && !edgeBox.withLock({ $0 })
        let pip = watch && pipShowing && pipControllable ? pipWindow.target : nil
        edgeWatcher.watch(watch ? peerEdge : nil, pip: pip)
    }

    /// Edge watcher's tap thread: the pointer was pushed over the edge facing the MacBook – or,
    /// with `pip`, moved into the picture-in-picture window at that spot (0…1 of the picture).
    private func beginEdgeSession(fraction: Double, pip: (n: CGPoint, target: PiPTarget)? = nil) {
        guard edgeBox.withLock({ let was = $0; $0 = true; return !was }) else { return }
        edgeWatcher.watch(nil)
        var enter = ControlMessage(.edgeEnter)
        // Always set (nil for the screen edge): never a target left over from an earlier session.
        pipSessionBox.withLock { $0 = pip?.target }
        if let pip {
            enter.pipX = pip.n.x
            enter.pipY = pip.n.y
            enter.pipScale = PiPGeometry.motionScale(macPoints: pipMacPoints.withLock { $0 }, video: pip.target.video)
        } else {
            enter.fraction = fraction
        }
        // Sent before the first forwarded event, so the MacBook positions its pointer first.
        control?.send(enter)
        input.setActive(true)
        DispatchQueue.main.async { [weak self] in
            guard let self, self.edgeBox.withLock({ $0 }) else { return }
            guard self.control != nil, self.mode == .local else {
                self.endEdgeSession(fraction: nil, notifyPeer: true)
                return
            }
            ddLog.notice("Maus und Tastatur steuern jetzt das MacBook")
            self.edgeActive = true
            self.controlQueue.async { self.lastPongNs = hostTimeNs() }
            // Freeze and hide this Mac's pointer while the MacBook is controlled (DuoDisplay is not
            // the active app here, so NSCursor.hide would not work).
            CGAssociateMouseAndMouseCursorPosition(0)
            BackgroundCursor.hide()
        }
    }

    /// Main thread. Keyboard and pointer belong to this Mac again; the pointer reappears at the
    /// edge at `fraction` (where it left the MacBook) or where it crossed over.
    private func endEdgeSession(fraction: Double?, notifyPeer: Bool) {
        guard edgeBox.withLock({ let was = $0; $0 = false; return was }) else { return }
        pipSessionBox.withLock { $0 = nil }
        ddLog.notice("Maus und Tastatur zurück auf diesem Mac")
        if mode != .display { input.setActive(false) }
        if notifyPeer { control?.send(ControlMessage(.edgeLeave)) }
        if let fraction { warpBack(fraction: fraction, carry: .zero) }
        finishEdgeSession()
    }

    /// controlQueue: the MacBook pushed the pointer back over the edge. Handled right here instead
    /// of on main (no extra hop while the hand stays on the trackpad), and the motion this Mac kept
    /// forwarding while the message was underway is replayed – the pointer keeps its momentum
    /// instead of sitting at the edge.
    private func edgeReturned(fraction: Double?, pipAt: CGPoint? = nil, pipSide: PiPSide? = nil,
                              eventTime: UInt64?, peerInfo: String? = nil) {
        guard edgeBox.withLock({ let was = $0; $0 = false; return was }) else { return }
        input.setActive(false)   // edge sessions only exist in "Normal nutzen"; main re-checks
        let carry = eventTime.map { input.motion(after: $0) } ?? InputCapture.Carry()
        let pipTarget = pipSessionBox.withLock { let t = $0; $0 = nil; return t }
        if let pipTarget {
            // Out of the picture: right outside the window, where the MacBook pointer left.
            // (No position = the MacBook refused; the pointer stays and has to leave the picture first.)
            if let pipAt, let pipSide {
                PointerWarp.move(to: PiPGeometry.landingPoint(side: pipSide, n: pipAt, video: pipTarget.video,
                                                              window: pipTarget.window, carry: carry.motion,
                                                              displays: EdgeGeometry.activeDisplays()))
            }
        } else if let fraction {
            warpBack(fraction: fraction, carry: carry.motion)
        }
        CGAssociateMouseAndMouseCursorPosition(1)
        let queuedNs = hostTimeNs()
        DispatchQueue.main.async { [weak self] in
            let mainLagMs = Double(hostTimeNs() &- queuedNs) / 1e6
            ddLog.notice("Maus und Tastatur zurück auf diesem Mac – Weg \(carry.exitAgeMs ?? -1, format: .fixed(precision: 1)) ms, nachgeholt \(carry.events) Bewegungen (\(carry.motion.dx, format: .fixed(precision: 0)), \(carry.motion.dy, format: .fixed(precision: 0))) pt, Zeitstempel \(eventTime != nil), Main \(mainLagMs, format: .fixed(precision: 1)) ms · \(peerInfo ?? "MacBook: keine Angaben (alte Version)", privacy: .public)")
            self?.finishEdgeSession()
        }
        // Diagnostics: how long until the pointer moves again after coming back (a freeze shows up here).
        let start = CGEvent(source: nil)?.location ?? .zero
        let returnedNs = hostTimeNs()
        func poll() {
            let now = hostTimeNs()
            let p = CGEvent(source: nil)?.location ?? start
            if p != start {
                ddLog.notice("Zeiger bewegt sich nach Rückkehr nach \(Double(now &- returnedNs) / 1e6, format: .fixed(precision: 0)) ms wieder")
            } else if now &- returnedNs > 800_000_000 {
                ddLog.notice("Zeiger hat sich nach Rückkehr 800 ms lang nicht bewegt")
            } else {
                controlQueue.asyncAfter(deadline: .now() + .milliseconds(4)) { poll() }
            }
        }
        controlQueue.asyncAfter(deadline: .now() + .milliseconds(4)) { poll() }
    }

    /// Any thread: puts the pointer back at the edge facing the MacBook, moved by `carry`.
    private func warpBack(fraction: Double, carry: CGVector) {
        guard let edge = peerEdgeBox.withLock({ $0 }) else { return }
        let displays = EdgeGeometry.activeDisplays()
        guard let entry = EdgeGeometry.entryPoint(edge: edge, fraction: fraction, displays: displays) else { return }
        PointerWarp.move(to: EdgeGeometry.landingPoint(entry: entry, carry: carry, displays: displays))
    }

    /// Main thread, after an edge session ended.
    private func finishEdgeSession() {
        if mode == .display {
            // Switched to display mode meanwhile: capture stays on, the pointer frozen.
            input.setActive(true)
            CGAssociateMouseAndMouseCursorPosition(0)
        } else {
            // Again here, so it wins over a just-queued freeze from beginEdgeSession.
            CGAssociateMouseAndMouseCursorPosition(1)
        }
        BackgroundCursor.show()
        edgeActive = false
        updateEdgeWatcher()
    }

    /// Display mode with the MacBook's sound on these speakers: volume up / down / mute change this
    /// Mac's output volume (they are not forwarded). Otherwise they go to the MacBook as before.
    private func updateVolumeKeys() {
        let here = mode == .display && peerAudioHere
        if input.volumeKeysStayHere != here {
            ddLog.notice("Lautstärketasten: \(here ? "steuern diesen Mac" : "gehen ans MacBook", privacy: .public)")
            input.volumeKeysStayHere = here
        }
    }

    private func activateInputCapture(_ on: Bool) {
        if on {
            guard input.isInstalled else { return }
            input.setActive(true)
            // Freeze and hide this Mac's own pointer; only the forwarded deltas matter.
            if !cursorHidden {
                CGAssociateMouseAndMouseCursorPosition(0)
                NSCursor.hide()
                cursorHidden = true
            }
        } else {
            input.setActive(false)
            if cursorHidden {
                CGAssociateMouseAndMouseCursorPosition(1)
                NSCursor.unhide()
                cursorHidden = false
            }
        }
    }

    // MARK: Clock sync (NTP-style, min-RTT filter)

    private func startPing(_ channel: ControlChannel) {
        pingTimer?.cancel()
        controlQueue.async {
            self.clock = ClockSync()
            self.lastPongNs = hostTimeNs()
        }
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(250))
        timer.setEventHandler { [weak self, weak channel] in
            var ping = ControlMessage(.ping)
            ping.t0 = hostTimeNs()
            channel?.send(ping)
            // The MacBook stopped answering while it is being controlled: give the input back here.
            if let self, self.edgeBox.withLock({ $0 }), hostTimeNs() &- self.lastPongNs > 1_500_000_000 {
                DispatchQueue.main.async { self.endEdgeSession(fraction: nil, notifyPeer: true) }
            }
        }
        timer.resume()
        pingTimer = timer
    }

    private func handlePong(_ message: ControlMessage) {
        guard let t0 = message.t0, let t1 = message.t1 else { return }
        lastPongNs = hostTimeNs()
        let offset = clock.add(t0: t0, t1: t1, t2: hostTimeNs())
        pipeline.setClockOffset(offset)
    }
}

struct ClockSync {
    private var samples: [(rtt: UInt64, offset: Int64)] = []

    /// Returns the offset (sender − receiver) of the lowest-RTT sample among the recent ones.
    mutating func add(t0: UInt64, t1: UInt64, t2: UInt64) -> Int64 {
        let rtt = t2 &- t0
        let offset = Int64(bitPattern: t1) &- Int64(bitPattern: t0 / 2 + t2 / 2)
        samples.append((rtt, offset))
        if samples.count > 20 { samples.removeFirst() }
        return samples.min { $0.rtt < $1.rtt }!.offset
    }
}
