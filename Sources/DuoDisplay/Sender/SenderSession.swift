import Foundation
import Network
import AppKit
import os

enum StreamQuality: Int, CaseIterable, Identifiable {
    case retina = 0     // full Retina pixels (2×)
    case balanced = 1   // Retina UI, streamed at 1.5×
    case fast = 2       // 1× (non-HiDPI)

    var id: Int { rawValue }
    var scale: Double { [2.0, 1.5, 1.0][rawValue] }
    var label: String {
        switch self {
        case .retina: return "Retina 2×, razor sharp"
        case .balanced: return "Balanced 1.5×, ~3 ms faster"
        case .fast: return "Fast 1×, minimal latency"
        }
    }
}

struct StreamSettings {
    var codec: VideoCodec = .prores   // falls back to HEVC without Thunderbolt / ProRes hardware
    var fps: Int = 0               // 0 = the receiver's refresh rate (60 Hz on an iMac)
    var bitrateMbps: Double = 150
    var quality: StreamQuality = .retina
    var thunderboltOnly: Bool = true
    var receiverOnRight: Bool = true
    var localCursor: Bool = true
    var systemAudio: Bool = true   // display mode: MacBook sound plays on the iMac
    var autoReduce: Bool = true    // lower the stream scale when the encoder cannot keep up
    var autoRestore: Bool = true   // …and raise it again once there is enough headroom
    var edgeSwitch: Bool = true    // "Normal Use": iMac pointer crosses over the edge to this Mac

    /// Edge of the receiver's screen that faces this Mac.
    var receiverEdge: ScreenEdge { receiverOnRight ? .left : .right }
}

/// Sender role (the MacBook): stays paired with the receiver and, in display mode, owns the
/// virtual display, streams it and replays the receiver's keyboard / trackpad input.
/// All @Published state is mutated on the main thread.
final class SenderSession: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting(String)
        case pairing(String)     // waiting for the user to compare the code on both Macs
        case connected(String)
        case failed(String)
    }

    struct Receiver: Identifiable, Equatable {
        let name: String
        let endpoint: NWEndpoint
        let thunderboltInterface: NWInterface?
        let otherInterfaces: [String]
        var id: String { name }

        static func == (a: Receiver, b: Receiver) -> Bool {
            a.name == b.name && a.thunderboltInterface?.name == b.thunderboltInterface?.name
                && a.otherInterfaces == b.otherInterfaces
        }
    }

    @Published private(set) var receivers: [Receiver] = []
    @Published private(set) var phase: Phase = .idle {
        didSet { connectedActivity.set(isConnected) }
    }
    private let connectedActivity = LatencyActivity(reason: "DuoDisplay is connected to the iMac")
    @Published private(set) var mode: LinkMode = .display
    @Published private(set) var streaming = false
    @Published private(set) var statsLine = ""
    @Published private(set) var detailLine = ""
    @Published private(set) var thunderboltLinks: [NetLink] = []
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted

    /// Receiver to (re)connect to automatically – survives app restarts.
    @Published private(set) var autoConnectName: String? = UserDefaults.standard.string(forKey: "sender.autoConnect") {
        didSet { UserDefaults.standard.set(autoConnectName, forKey: "sender.autoConnect") }
    }

    @Published private(set) var audioLine = ""
    /// "Normal Use": keyboard and pointer of the iMac currently control this Mac.
    @Published private(set) var edgeActive = false
    /// "Normal Use": the iMac shows this Mac's main screen as picture-in-picture (⌃⌥⌘P).
    @Published private(set) var pipStreaming = false {
        didSet { pipBox.withLock { $0 = pipStreaming } }
    }
    /// Copy of `pipStreaming` for controlQueue.
    private let pipBox = OSAllocatedUnfairLock(initialState: false)
    /// The current edge session came in through the picture-in-picture window (not over the edge).
    private let pipSessionBox = OSAllocatedUnfairLock(initialState: false)
    /// Screen shown in the picture-in-picture window: the main screen (mirrored) or the extra
    /// virtual one (extended). For controlQueue.
    private let pipDisplayBox = OSAllocatedUnfairLock<CGDirectDisplayID>(initialState: 0)
    /// Last pipState sent for the running picture-in-picture stream (sent again when the
    /// Accessibility permission changes – it decides whether the iMac lets the pointer in). Main thread.
    private var pipState: ControlMessage?
    /// The iMac this MacBook is paired with (only that one is trusted).
    @Published private(set) var pairedName: String?

    var settingsProvider: () -> StreamSettings = { StreamSettings() }

    /// Camera + microphone of the iMac as virtual devices on this Mac.
    let media = MediaHub()
    let pairingPrompt = PairingPrompt()
    private var pairingObserver: NSObjectProtocol?

    var isConnected: Bool { if case .connected = phase { return true } else { return false } }
    var isBusy: Bool {
        switch phase {
        case .connecting, .pairing, .connected: return true
        default: return false
        }
    }
    var connectedName: String? {
        switch phase {
        case .connecting(let n), .pairing(let n), .connected(let n): return n
        default: return nil
        }
    }

    private var browser: NWBrowser?
    /// Also read on controlQueue and the cursor tracker's tap thread, hence the lock.
    private let controlBox = OSAllocatedUnfairLock<ControlChannel?>(initialState: nil)
    private var control: ControlChannel? {
        get { controlBox.withLock { $0 } }
        set { controlBox.withLock { $0 = newValue } }
    }
    private var connection: NWConnection?
    /// Seals everything this Mac sends over UDP to the iMac (video, sound) – the MacBook → iMac
    /// media key of the current connection; nil until it has authenticated.
    private var mediaSealer: MediaSealer?
    private var virtualDisplay: VirtualDisplay?
    private let pipelineBox = OSAllocatedUnfairLock<StreamPipeline?>(initialState: nil)
    private let modeBox = OSAllocatedUnfairLock(initialState: LinkMode.local)   // readable from controlQueue
    /// "Normal Use" and the iMac pointer is on this Mac (input is injected).
    private let edgeBox = OSAllocatedUnfairLock(initialState: false)
    private let controlQueue = DispatchQueue(label: "duodisplay.sender.control", qos: .userInteractive)
    private let injector = InputInjector()       // controlQueue only
    private let cursorTracker = CursorTracker()
    private var cursorTracking = false
    private var statsTimer: Timer?
    private var pollTimer: Timer?
    private var activity: NSObjectProtocol?
    private var remoteStats: ControlMessage?
    private var settings = StreamSettings()
    /// Virtual display currently in use and what it was created with (reused across stream restarts,
    /// so a settings change does not make the extra screen disappear and its windows jump around).
    private struct DisplayKey: Equatable {
        var pixelW, pixelH, pointW, pointH, fps: Int
        var hiDPI, placeRight: Bool
    }
    private var displayKey: DisplayKey?
    /// Lowered automatically when the encoder cannot keep up (reset on connect / quality change).
    private var autoScaleCap: Double?
    private var streamScale = 2.0
    /// Highest scale the current settings allow (chosen quality, limited by the receiver's screen).
    private var maxStreamScale = 2.0
    private var slowSeconds = 0
    /// Consecutive seconds in which the encoder had enough headroom for the next higher scale.
    private var fastSeconds = 0
    /// Seconds of headroom needed before stepping up again; doubles when a step-up had to be undone soon after.
    private var restoreDelay = SenderSession.restoreDelayInitial
    private var lastAutoRaise: Date?
    private var receiverName = ""
    private var lastAutoAttempt = Date.distantPast
    private var audioTap: SystemAudioTap?
    private var audioSender: AudioSender?
    /// Where the running stream goes (sound uses the same UDP port); nil while not streaming.
    private var audioTarget: (host: NWEndpoint.Host, port: UInt16, interface: NWInterface?)?
    private var started = false

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        pairedName = PairingStore.shared.peer?.name
        if pairingObserver == nil {
            pairingObserver = NotificationCenter.default.addObserver(forName: PairingStore.didChange, object: nil,
                                                                     queue: .main) { [weak self] _ in
                self?.pairedName = PairingStore.shared.peer?.name
            }
        }
        media.start()
        startBrowsing()
        refreshPeriodic()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refreshPeriodic() }
    }

    func stopAll() {
        teardown()
        phase = .idle
        browser?.cancel()
        browser = nil
        media.stop()
        pollTimer?.invalidate()
        pollTimer = nil
        started = false
    }

    private func refreshPeriodic() {
        let links = NetInfo.thunderboltLinks()
        if links != thunderboltLinks { thunderboltLinks = links }
        let granted = Permissions.accessibilityGranted
        if granted != accessibilityGranted {
            accessibilityGranted = granted
            sendEdgeConfig()
            if pipStreaming, var state = pipState {
                state.pipControl = granted
                pipState = state
                control?.send(state)
            }
        }
        autoConnectIfPossible()
    }

    // MARK: Discovery

    private func startBrowsing() {
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjour(type: DD.bonjourType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed = state {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    guard let self, self.started else { return }
                    self.browser?.cancel()
                    self.startBrowsing()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        let tbNames = NetInfo.thunderboltNames()
        let ownName = localComputerName()
        var byName: [String: Receiver] = [:]
        for result in results {
            guard case let .service(name, _, _, _) = result.endpoint, name != ownName else { continue }
            let tb = result.interfaces.first { NetInfo.isThunderbolt($0.name, tbNames: tbNames) }
            let others = result.interfaces.map(\.name).filter { $0 != tb?.name }
            if let existing = byName[name] {
                byName[name] = Receiver(name: name,
                                        endpoint: existing.thunderboltInterface != nil ? existing.endpoint : result.endpoint,
                                        thunderboltInterface: existing.thunderboltInterface ?? tb,
                                        otherInterfaces: Array(Set(existing.otherInterfaces + others)).sorted())
            } else {
                byName[name] = Receiver(name: name, endpoint: result.endpoint,
                                        thunderboltInterface: tb, otherInterfaces: others.sorted())
            }
        }
        let sorted = byName.values.sorted { $0.name < $1.name }
        if sorted != receivers { receivers = sorted }
        autoConnectIfPossible()
    }

    private func autoConnectIfPossible() {
        guard started, !isBusy, let name = autoConnectName,
              let receiver = receivers.first(where: { $0.name == name }),
              Date().timeIntervalSince(lastAutoAttempt) > 3 else { return }
        if settingsProvider().thunderboltOnly && receiver.thunderboltInterface == nil { return }
        lastAutoAttempt = Date()
        // After a re-plug / restart start in normal mode – the iMac only becomes a display on request.
        connect(to: receiver, initialMode: .local, isAuto: true)
    }

    // MARK: Connection

    func connect(to receiver: Receiver, initialMode: LinkMode = .display, isAuto: Bool = false) {
        teardown()
        settings = settingsProvider()
        resetAutoScale()
        if settings.thunderboltOnly && receiver.thunderboltInterface == nil {
            phase = .failed("“\(receiver.name)” is not reachable over Thunderbolt. Check the cable or turn off “Connect over Thunderbolt only”.")
            return
        }
        if !isAuto { autoConnectName = receiver.name }
        receiverName = receiver.name
        remoteStats = nil
        mode = initialMode
        modeBox.withLock { $0 = initialMode }
        phase = .connecting(receiver.name)

        let connection = NWConnection(to: receiver.endpoint,
                                      using: Net.tcpParameters(requiredInterface: receiver.thunderboltInterface))
        let channel = ControlChannel(connection: connection, queue: controlQueue)
        // Only a user-initiated connection may pair (that needs the user on both Macs anyway).
        let handshake = ClientHandshake(channel: channel, allowPairing: !isAuto)
        handshake.onEvent = { [weak self, weak channel] event in
            DispatchQueue.main.async {
                guard let self, let channel, self.control === channel else { return }
                self.handleHandshake(event, handshake: handshake, channel: channel, receiver: receiver)
            }
        }
        channel.onReady = { [weak self, weak channel] in
            // udpPort: the iMac camera + microphone are sent there.
            channel?.send(handshake.hello(name: localComputerName(), udpPort: self?.media.port))
        }
        channel.onMessage = { [weak self, weak channel] message in
            guard let self else { return }
            // Until the iMac has proven it is the paired Mac, only the handshake is processed.
            guard handshake.isAuthenticated else { return handshake.handle(message) }
            switch message.kind {
            case .keyframeRequest:
                self.pipelineBox.withLock { $0 }?.requestKeyframe()
            case .ping:
                var pong = ControlMessage(.pong)
                pong.t0 = message.t0
                pong.t1 = hostTimeNs()
                channel?.send(pong)
            case .displayInfo:
                DispatchQueue.main.async { self.startStreaming(message) }
            case .requestMode:
                if let requested = message.mode {
                    if requested == .local {
                        // Stop injecting right away (we are on controlQueue).
                        self.modeBox.withLock { $0 = .local }
                        self.injector.releaseAll()
                    }
                    DispatchQueue.main.async { self.setMode(requested) }
                }
            case .stats:
                DispatchQueue.main.async { self.remoteStats = message }
            case .mediaStatus:
                DispatchQueue.main.async { self.media.handleStatus(message.text) }
            case .pipStart:
                DispatchQueue.main.async { self.startPiPStream(message) }
            case .pipStop:
                DispatchQueue.main.async { if self.pipStreaming { self.stopStream() } }
            case .edgeEnter where message.pipX != nil:
                // The iMac pointer moved into the picture-in-picture window.
                guard let channel, self.control === channel else { return }
                guard self.modeBox.withLock({ $0 }) == .local, self.pipBox.withLock({ $0 }),
                      Permissions.accessibilityGranted else {
                    channel.send(ControlMessage(.edgeLeave))
                    return
                }
                self.pipSessionBox.withLock { $0 = true }
                self.edgeBox.withLock { $0 = true }
                let display = self.pipDisplayBox.withLock { $0 }
                self.injector.beginPiPSession(n: CGPoint(x: message.pipX ?? 0.5, y: message.pipY ?? 0.5),
                                              scale: message.pipScale ?? 1,
                                              display: display != 0 ? display : CGMainDisplayID())
                DispatchQueue.main.async { self.edgeActive = self.edgeBox.withLock { $0 } }
                if self.control !== channel { self.endEdgeSession(notifyReceiver: false) }
            case .edgeEnter:
                // Only from the current connection, only in "Normal Use" and only if the user
                // still wants it (settings may just have changed).
                guard let channel, self.control === channel else { return }
                let settings = self.settingsProvider()
                guard self.modeBox.withLock({ $0 }) == .local, settings.edgeSwitch else {
                    channel.send(ControlMessage(.edgeLeave))
                    return
                }
                self.pipSessionBox.withLock { $0 = false }
                self.edgeBox.withLock { $0 = true }
                self.injector.beginEdgeSession(edge: settings.receiverEdge.opposite, fraction: message.fraction ?? 0.5)
                DispatchQueue.main.async { self.edgeActive = self.edgeBox.withLock { $0 } }
                // teardown() may have run meanwhile (it clears `control` before ending the edge session).
                if self.control !== channel { self.endEdgeSession(notifyReceiver: false) }
            case .edgeLeave:
                self.endEdgeSession(notifyReceiver: false)
            default:
                break
            }
        }
        channel.onBinary = { [weak self] kind, data in
            guard let self, handshake.isAuthenticated, kind == .inputEvent,
                  self.modeBox.withLock({ $0 }) == .display || self.edgeBox.withLock({ $0 }) else { return }
            self.injector.handle(data)
        }
        injector.onEdgeExit = { [weak self, weak channel] fraction, eventTime, info in
            // controlQueue: the pointer was pushed back over the edge – the iMac takes over again.
            guard let self, self.edgeBox.withLock({ let was = $0; $0 = false; return was }) else { return }
            var leave = ControlMessage(.edgeLeave)
            leave.fraction = fraction
            leave.eventTime = eventTime
            leave.text = info
            channel?.send(leave)
            self.injector.releaseAll()
            DispatchQueue.main.async { self.edgeActive = false }
        }
        injector.onPiPExit = { [weak self, weak channel] n, side, eventTime in
            // controlQueue: the pointer was pushed out of the main screen – back into the iMac,
            // right outside the picture-in-picture window.
            guard let self, self.edgeBox.withLock({ let was = $0; $0 = false; return was }) else { return }
            var leave = ControlMessage(.edgeLeave)
            leave.pipX = n.x
            leave.pipY = n.y
            leave.pipSide = side
            leave.eventTime = eventTime
            channel?.send(leave)
            self.injector.releaseAll()
            DispatchQueue.main.async { self.edgeActive = false }
        }
        channel.onClose = { [weak self, weak channel] error in
            DispatchQueue.main.async {
                guard let self, let channel, self.control === channel else { return }
                self.teardown()
                self.phase = error.map { .failed("Disconnected: \($0.localizedDescription)") } ?? .idle
            }
        }
        control = channel
        self.connection = connection
        channel.start()

        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self, weak channel] in
            guard let self, let channel, self.control === channel, case .connecting = self.phase else { return }
            self.teardown()
            self.phase = .failed("Timed out connecting to “\(receiver.name)”.")
        }
    }

    /// Main thread: result of the pairing / authentication handshake of the current connection.
    private func handleHandshake(_ event: ClientHandshake.Event, handshake: ClientHandshake,
                                 channel: ControlChannel, receiver: Receiver) {
        switch event {
        case .authenticated(_, let keys):
            pairingPrompt.close()
            phase = .connected(receiver.name)
            mediaSealer = MediaSealer(key: keys.toReceiver)
            media.attach(incoming: MediaOpener(key: keys.toSender)) { [weak channel] message in channel?.send(message) }
            setMode(mode, force: true)
            sendEdgeConfig()
        case .pairingCode(let code, let peerName):
            phase = .pairing(receiver.name)
            // Only reached while this Mac is not paired (ClientHandshake refuses otherwise).
            let viaThunderbolt = channel.connection.currentPath?.availableInterfaces.first
                .map { NetInfo.isThunderbolt($0.name, tbNames: NetInfo.thunderboltNames()) } ?? false
            pairingPrompt.show(
                code: code, peerName: peerName,
                note: viaThunderbolt ? nil : PairingPrompt.notThunderboltNote(channel.connection),
                onConfirm: { [weak self] in self?.controlQueue.async { handshake.confirmPairing() } },
                onCancel: { [weak self] in
                    guard let self else { return }
                    self.controlQueue.async {
                        handshake.cancelPairing()
                        DispatchQueue.main.async {
                            guard self.control === channel else { return }
                            self.disconnect()
                        }
                    }
                })
        case .paired:
            pairingPrompt.close()   // the iMac's authChallenge follows right away
        case .notPaired(let peerName):
            teardown()
            autoConnectName = nil   // no automatic retries – pairing needs the user
            if let paired = PairingStore.shared.peer {
                phase = .failed("“\(peerName)” doesn’t recognize this MacBook (paired with “\(paired.name)”). To pair again, choose “Unpair” on both Macs, then “Connect” here.")
            } else {
                phase = .failed("“\(peerName)” is not paired with this MacBook. Click “Connect” to pair.")
            }
        case .failed(let text):
            teardown()
            phase = .failed(text)
        }
    }

    /// User-initiated: also stops automatic reconnects.
    func disconnect() {
        autoConnectName = nil
        teardown()
        phase = .idle
    }

    /// Forgets the paired iMac; the next "Connect" pairs again.
    func forgetPairing() {
        PairingStore.shared.forget()
        disconnect()
    }

    // MARK: Modes

    /// ⌃⌥⌘D on this Mac, menu, or button.
    func toggleMode() {
        if case .pairing = phase { return }   // finish (or cancel) the pairing first
        guard isConnected else {
            // Not connected: treat the hotkey as "connect and show".
            if let name = autoConnectName ?? receivers.first?.name,
               let receiver = receivers.first(where: { $0.name == name }) {
                connect(to: receiver, initialMode: .display)
            }
            return
        }
        setMode(mode == .display ? .local : .display)
    }

    func setMode(_ newMode: LinkMode, force: Bool = false) {
        guard let control, isConnected else { return }
        guard force || newMode != mode else { return }
        endEdgeSession(notifyReceiver: true)
        if pipStreaming { stopStream() }   // the iMac closes the window on its side
        mode = newMode
        modeBox.withLock { $0 = newMode }
        if newMode == .local {
            stopStream()
            controlQueue.async { self.injector.releaseAll() }
        } else {
            settings = settingsProvider()
        }
        var message = ControlMessage(.setMode)
        message.mode = newMode
        message.localCursor = settings.localCursor && accessibilityGranted
        control.send(message)
        // For .display the receiver answers with displayInfo → startStreaming.
    }

    /// ⌃⌥⌘P on this Mac: the iMac shows or hides this Mac's screen as picture-in-picture.
    func requestPiPToggle() {
        guard let control, isConnected else { return }
        control.send(ControlMessage(.pipToggle))
    }

    /// "Normal Use": tells the receiver which of its screen edges leads here (or that crossing is off).
    /// Off without the Accessibility permission – input could not be injected, the iMac would be stuck.
    func sendEdgeConfig() {
        guard let control, isConnected else { return }
        let fresh = settingsProvider()
        var message = ControlMessage(.edgeConfig)
        message.edge = fresh.edgeSwitch && accessibilityGranted ? fresh.receiverEdge : nil
        // A session through the picture-in-picture window does not need the edge switch, only the permission.
        if message.edge == nil, !accessibilityGranted || !pipSessionBox.withLock({ $0 }) {
            endEdgeSession(notifyReceiver: true)
        }
        control.send(message)
    }

    /// Stops injecting the iMac's input (any thread). The receiver is told unless it started this.
    private func endEdgeSession(notifyReceiver: Bool) {
        guard edgeBox.withLock({ let was = $0; $0 = false; return was }) else { return }
        if notifyReceiver { control?.send(ControlMessage(.edgeLeave)) }
        controlQueue.async {
            self.injector.endEdgeSession()
            self.injector.releaseAll()
        }
        DispatchQueue.main.async { self.edgeActive = false }
    }

    /// The user changed a stream setting: apply it right away if the iMac is showing this Mac.
    /// Debounced, so dragging the bitrate slider restarts the stream once, not on every step.
    func settingsChanged(qualityChanged: Bool = false) {
        if qualityChanged { resetAutoScale() }
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.isConnected, self.mode == .display else { return }
            self.setMode(.display, force: true)   // the receiver answers with displayInfo → startStreaming
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }
    private var pendingRestart: DispatchWorkItem?

    /// The automatic-resolution toggles changed. Switching the reduction off brings back the full
    /// resolution right away; otherwise nothing needs a restart (updateStats reads the new values).
    func autoScaleSettingsChanged() {
        let fresh = settingsProvider()
        settings.autoReduce = fresh.autoReduce
        settings.autoRestore = fresh.autoRestore
        slowSeconds = 0
        fastSeconds = 0
        if !fresh.autoReduce && autoScaleCap != nil {
            resetAutoScale()
            settingsChanged()
        } else if isConnected && mode == .display && streaming {
            detailLine = detailText()
        }
    }

    private func resetAutoScale() {
        autoScaleCap = nil
        restoreDelay = Self.restoreDelayInitial
        lastAutoRaise = nil
        slowSeconds = 0
        fastSeconds = 0
    }

    // MARK: Streaming

    private func teardown() {
        // Cleared first: an edgeEnter still in flight on controlQueue checks it (see onMessage).
        let channel = control
        control = nil
        pairingPrompt.close()
        stopStream()
        endEdgeSession(notifyReceiver: false)
        modeBox.withLock { $0 = .local }
        controlQueue.async { self.injector.releaseAll() }
        media.detach()
        mediaSealer = nil
        connection = nil
        channel?.close()
    }

    private func stopStream(keepDisplay: Bool = false) {
        slowSeconds = 0
        fastSeconds = 0
        statsTimer?.invalidate()
        statsTimer = nil
        statsLine = ""
        detailLine = ""
        audioLine = ""
        streaming = false
        pipStreaming = false
        pipState = nil
        stopSystemAudio()
        audioTarget = nil
        if cursorTracking { cursorTracker.stop(); cursorTracking = false }
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil

        let pipeline = pipelineBox.withLock { box -> StreamPipeline? in
            let p = box
            box = nil
            return p
        }
        let display = keepDisplay ? nil : virtualDisplay
        if !keepDisplay {
            virtualDisplay = nil
            displayKey = nil
        }
        guard pipeline != nil || display != nil else { return }
        Task {
            await pipeline?.stop()
            // Remove the virtual display only after capture stopped; its windows move to the MacBook.
            await MainActor.run { withExtendedLifetime(display) {} }
        }
    }

    private func startStreaming(_ info: ControlMessage) {
        guard mode == .display, let connection, let sealer = mediaSealer else { return }
        guard let udpPort = info.udpPort, let session = info.session,
              let pixelW = info.pixelWidth, let pixelH = info.pixelHeight,
              let pointW = info.pointWidth, let pointH = info.pointHeight,
              case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else {
            phase = .failed("Invalid response from the receiver.")
            teardown()
            return
        }
        settings = settingsProvider()

        // By default the virtual display runs at the receiver's refresh rate. 120 Hz on a 60 Hz iMac
        // saves at most a few ms, but doubles what the MacBook has to draw, capture and encode
        // (4480×2520 for a 4.5K iMac); under load that cost far more than it gained (18–30 fps).
        let receiverHz = info.refreshRate.flatMap { $0 > 0 ? $0 : nil } ?? 60
        let fps = max(30, min(settings.fps > 0 ? settings.fps : receiverHz, 120))
        let receiverScale = Double(pixelW) / Double(max(pointW, 1))
        maxStreamScale = min(settings.quality.scale, receiverScale)
        if !settings.autoReduce { autoScaleCap = nil }
        let scale = min(maxStreamScale, autoScaleCap ?? .infinity)
        streamScale = scale
        // The virtual display renders Retina UI whenever the chosen quality is above 1×; ScreenCaptureKit
        // scales on the GPU to the stream size (cheap) if that is below the full pixel size – also when
        // the stream was reduced automatically, so the extra screen itself stays the same.
        let hiDPI = receiverScale > 1.01 && min(settings.quality.scale, receiverScale) > 1.01
        let displayW = hiDPI ? pixelW : pointW
        let displayH = hiDPI ? pixelH : pointH
        let width = Int((Double(pointW) * scale).rounded()) & ~1
        let height = Int((Double(pointH) * scale).rounded()) & ~1

        let pathInterface = connection.currentPath?.availableInterfaces.first
        let localMTU = pathInterface.flatMap { NetInfo.mtu(of: $0.name) } ?? 1500
        let mtu = min(localMTU, info.mtu ?? 1500)
        let datagram = max(DD.minDatagramSize, min(mtu - 64, DD.maxDatagramSize))

        let key = DisplayKey(pixelW: displayW, pixelH: displayH, pointW: pointW, pointH: pointH, fps: fps,
                             hiDPI: hiDPI, placeRight: settings.receiverOnRight)
        let reuse = virtualDisplay != nil && displayKey == key
        stopStream(keepDisplay: reuse)

        let display: VirtualDisplay
        if reuse, let existing = virtualDisplay {
            display = existing
        } else {
            guard let created = VirtualDisplay(
                name: "DuoDisplay – \(receiverName)", serial: stableHash(receiverName),
                pixelWidth: displayW, pixelHeight: displayH, pointWidth: pointW, pointHeight: pointH,
                refreshRate: fps, hiDPI: hiDPI, placeRight: settings.receiverOnRight) else {
                statsLine = "Could not create the virtual display."
                return
            }
            display = created
            virtualDisplay = created
            displayKey = key
        }

        let onThunderbolt = pathInterface.map { NetInfo.isThunderbolt($0.name, tbNames: NetInfo.thunderboltNames()) } ?? false
        let pipeline: StreamPipeline, codec: VideoCodec, codecNote: String
        do {
            (pipeline, codec, codecNote) = try makePipeline(
                width: width, height: height, fps: fps, host: host, port: udpPort, session: session,
                datagram: datagram, interface: pathInterface, sealer: sealer, onThunderbolt: onThunderbolt,
                receiverProRes: info.proRes == true)
        } catch {
            statsLine = error.localizedDescription
            stopStream()
            return
        }
        pipeline.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pipelineBox.withLock({ $0 }) === pipeline else { return }
                self.statsLine = "Screen capture stopped: \(error.localizedDescription)"
            }
        }
        pipelineBox.withLock { $0 = pipeline }

        // Local cursor: the receiver draws the pointer itself, so the video must not contain it.
        var localCursor = false
        if settings.localCursor && accessibilityGranted {
            cursorTracker.onPosition = { [weak self] payload in self?.control?.send(.cursorPosition, payload) }
            cursorTracker.onImage = { [weak self] message in self?.control?.send(message) }
            localCursor = cursorTracker.start(display: display.displayID)
            cursorTracking = localCursor
        }

        audioTarget = (host, udpPort, pathInterface)
        if settings.systemAudio { startSystemAudio(host: host, port: udpPort, interface: pathInterface) }

        let link = pathInterface.map { iface -> String in
            onThunderbolt ? "Thunderbolt (\(iface.name))" : iface.name
        } ?? "?"
        ddLog.notice("Stream starting: \(width)×\(height) @ \(fps) Hz, \(codec.label, privacy: .public)\(codecNote, privacy: .public), local pointer \(localCursor)")
        let rate = codec.isIntraOnly ? "Bitrate automatisch" : "\(Int(settings.bitrateMbps)) Mbit/s"
        detailBase = "\(width)×\(height) @ \(fps) Hz · \(codec.label)\(codecNote) · \(rate) · \(link) · \(datagram) B/packet"
            + (localCursor ? " · local pointer" : "")
            + (pipeline.hardwareEncoder ? "" : " · ⚠︎ software encoder")
        detailLine = detailText()

        Task {
            do {
                try await pipeline.start(displayID: display.displayID, showsCursor: !localCursor)
                await MainActor.run {
                    guard self.pipelineBox.withLock({ $0 }) === pipeline else { return }
                    self.streaming = true
                    self.controlQueue.async {
                        // Only for a fresh extra screen; a restart after a settings change keeps the pointer where it is.
                        if !reuse { self.injector.warp(toCenterOf: display.displayID) }
                        DispatchQueue.main.async { self.cursorTracker.reportCurrentPosition() }
                    }
                    self.activity = ProcessInfo.processInfo.beginActivity(
                        options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled],
                        reason: "DuoDisplay is streaming a display")
                    self.statsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                        self?.updateStats()
                    }
                }
            } catch {
                await MainActor.run {
                    guard self.pipelineBox.withLock({ $0 }) === pipeline else { return }
                    self.stopStream()
                    self.statsLine = "Screen capture failed: \(error.localizedDescription). Allow DuoDisplay in System Settings → Privacy & Security → Screen & System Audio Recording."
                }
            }
        }
    }

    /// Encoder + sender for a stream: the chosen codec, falling back to HEVC where ProRes cannot work.
    private func makePipeline(width: Int, height: Int, fps: Int, host: NWEndpoint.Host, port: UInt16, session: UInt8,
                              datagram: Int, interface: NWInterface?, sealer: MediaSealer, onThunderbolt: Bool,
                              receiverProRes: Bool) throws -> (StreamPipeline, VideoCodec, String) {
        // ProRes needs ~4× the data rate of HEVC and hardware on both ends; otherwise stream HEVC.
        var codec = settings.codec
        var codecNote = ""
        if codec == .prores {
            if !onThunderbolt { codec = .hevc; codecNote = " (ProRes needs Thunderbolt)" }
            else if !receiverProRes { codec = .hevc; codecNote = " (iMac can’t do ProRes, update DuoDisplay there)" }
        }
        func make(_ codec: VideoCodec) throws -> StreamPipeline {
            try StreamPipeline(codec: codec, width: width, height: height, fps: fps,
                               bitrateMbps: settings.bitrateMbps, host: host, port: port,
                               session: session, datagramSize: datagram, interface: interface, sealer: sealer)
        }
        var pipeline: StreamPipeline
        do {
            pipeline = try make(codec)
        } catch where codec == .prores {
            codec = .hevc; codecNote = " (ProRes encoder unavailable)"
            pipeline = try make(codec)
        }
        if codec == .prores && !pipeline.hardwareEncoder {
            pipeline.cancel()
            codec = .hevc; codecNote = " (no ProRes hardware encoder)"
            pipeline = try make(codec)
        }
        return (pipeline, codec, codecNote)
    }

    // MARK: Picture-in-picture (⌃⌥⌘P on either Mac, "Normal Use")

    /// The iMac opened the picture-in-picture window (or switched it between mirrored and extended):
    /// stream this Mac's main screen, or with `pipExtended` an extra virtual screen of the same size
    /// (no sound). At most 1.5× – the window is a fraction of the iMac's screen.
    private func startPiPStream(_ info: ControlMessage) {
        guard mode == .local, isConnected, let connection else { return }
        func fail(_ text: String) {
            var state = ControlMessage(.pipState)
            state.pip = false
            state.text = text
            control?.send(state)
        }
        guard let udpPort = info.udpPort, let session = info.session, let sealer = mediaSealer,
              case let .hostPort(host, _)? = connection.currentPath?.remoteEndpoint else {
            return fail("Invalid request from the iMac.")
        }
        stopStream()   // also removes the extra screen of an extended picture (its windows move here)
        settings = settingsProvider()

        let extended = info.pipExtended == true
        let mainID = CGMainDisplayID()
        let mainBounds = CGDisplayBounds(mainID)
        let pointW = Int(mainBounds.width), pointH = Int(mainBounds.height)
        let nativeScale = CGDisplayCopyDisplayMode(mainID).map { Double($0.pixelWidth) / Double(max($0.width, 1)) } ?? 1
        let scale = max(1, min(settings.quality.scale, nativeScale, 1.5))
        let width = Int((Double(pointW) * scale).rounded()) & ~1
        let height = Int((Double(pointH) * scale).rounded()) & ~1
        let receiverHz = info.refreshRate.flatMap { $0 > 0 ? $0 : nil } ?? 60
        let fps = max(30, min(settings.fps > 0 ? settings.fps : receiverHz, 60))

        // Extended: an extra screen as large as the main one (the picture keeps its shape when
        // switching), Retina like the main screen. It goes on the side away from the iMac, so
        // crossing over the screen edge between the two Macs still lands on the main screen.
        let displayID: CGDirectDisplayID
        if extended {
            let hiDPI = nativeScale > 1.01
            guard let created = VirtualDisplay(
                name: "DuoDisplay – Picture-in-Picture", serial: stableHash(receiverName + " PiP"),
                pixelWidth: hiDPI ? pointW * 2 : pointW, pixelHeight: hiDPI ? pointH * 2 : pointH,
                pointWidth: pointW, pointHeight: pointH, refreshRate: fps, hiDPI: hiDPI,
                placeRight: !settings.receiverOnRight) else {
                return fail("Could not create the extra display for picture-in-picture.")
            }
            virtualDisplay = created
            displayKey = nil   // never reused by the display mode
            displayID = created.displayID
        } else {
            displayID = mainID
        }
        pipDisplayBox.withLock { $0 = displayID }

        let pathInterface = connection.currentPath?.availableInterfaces.first
        let localMTU = pathInterface.flatMap { NetInfo.mtu(of: $0.name) } ?? 1500
        let mtu = min(localMTU, info.mtu ?? 1500)
        let datagram = max(DD.minDatagramSize, min(mtu - 64, DD.maxDatagramSize))
        let onThunderbolt = pathInterface.map { NetInfo.isThunderbolt($0.name, tbNames: NetInfo.thunderboltNames()) } ?? false

        let pipeline: StreamPipeline, codec: VideoCodec, codecNote: String
        do {
            (pipeline, codec, codecNote) = try makePipeline(
                width: width, height: height, fps: fps, host: host, port: udpPort, session: session,
                datagram: datagram, interface: pathInterface, sealer: sealer, onThunderbolt: onThunderbolt,
                receiverProRes: info.proRes == true)
        } catch {
            stopStream()
            return fail(error.localizedDescription)
        }
        pipeline.onError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.pipelineBox.withLock({ $0 }) === pipeline else { return }
                self.stopStream()
                fail("Screen capture stopped: \(error.localizedDescription)")
            }
        }
        pipelineBox.withLock { $0 = pipeline }
        pipStreaming = true

        var localCursor = false
        if settings.localCursor && accessibilityGranted {
            cursorTracker.onPosition = { [weak self] payload in self?.control?.send(.cursorPosition, payload) }
            cursorTracker.onImage = { [weak self] message in self?.control?.send(message) }
            localCursor = cursorTracker.start(display: displayID)
            cursorTracking = localCursor
        }
        let kind = extended ? "erweitert" : "gespiegelt"
        ddLog.notice("Picture-in-picture starting (\(kind, privacy: .public)): \(width)×\(height) @ \(fps) Hz, \(codec.label, privacy: .public)\(codecNote, privacy: .public), local pointer \(localCursor)")
        detailLine = "Picture-in-picture on \(receiverName) (\(kind)): \(width)×\(height) @ \(fps) Hz · \(codec.label)\(codecNote)"

        Task {
            do {
                try await pipeline.start(displayID: displayID, showsCursor: !localCursor)
                await MainActor.run {
                    guard self.pipelineBox.withLock({ $0 }) === pipeline else { return }
                    var state = ControlMessage(.pipState)
                    state.pip = true
                    state.pointWidth = pointW
                    state.pointHeight = pointH
                    state.localCursor = localCursor
                    state.pipControl = self.accessibilityGranted
                    state.pipExtended = extended
                    self.pipState = state
                    self.control?.send(state)
                    self.cursorTracker.reportCurrentPosition()
                }
            } catch {
                await MainActor.run {
                    guard self.pipelineBox.withLock({ $0 }) === pipeline else { return }
                    self.stopStream()
                    fail("Screen capture failed: \(error.localizedDescription). On the MacBook, allow DuoDisplay in Privacy & Security → Screen & System Audio Recording.")
                }
            }
        }
    }

    private var detailBase = ""

    private func detailText() -> String {
        guard autoScaleCap != nil, streamScale < maxStreamScale - 0.01 else { return detailBase }
        return detailBase + String(format: " · reduced to %.1f× (encoder too slow)", streamScale)
            + (settings.autoRestore ? ", raises again when possible" : "")
    }

    // MARK: Sound → iMac

    private func startSystemAudio(host: NWEndpoint.Host, port: UInt16, interface: NWInterface?) {
        guard let sealer = mediaSealer else { return }
        let sender = AudioSender(host: host, port: port, kind: .systemAudio, interface: interface, sealer: sealer)
        let tap = SystemAudioTap()
        tap.onAudio = { samples, frames, channels, rate in
            sender.push(samples, frames: frames, channels: channels, sampleRate: rate)
        }
        do {
            try tap.start()
            audioTap = tap
            audioSender = sender
            audioLine = "Sound plays on \(receiverName); the MacBook is muted meanwhile."
            sendAudioRoute(true)
        } catch {
            sender.cancel()
            audioLine = "Sound stays on the MacBook: \(error.localizedDescription)"
        }
    }

    private func stopSystemAudio() {
        if audioTap != nil { sendAudioRoute(false) }
        audioTap?.stop()
        audioTap = nil
        audioSender?.cancel()
        audioSender = nil
    }

    /// Tells the iMac whether this Mac's sound plays there: the volume keys then change the iMac's
    /// volume instead of being forwarded here (this Mac is muted by the tap anyway).
    private func sendAudioRoute(_ on: Bool) {
        var message = ControlMessage(.audioRoute)
        message.audio = on
        control?.send(message)
    }

    /// The "Play sound on the iMac" toggle changed: start or stop the sound transfer of the running
    /// stream right away (the video keeps running).
    func systemAudioChanged() {
        let wanted = settingsProvider().systemAudio
        settings.systemAudio = wanted
        guard let target = audioTarget else { return }
        if wanted && audioTap == nil {
            startSystemAudio(host: target.host, port: target.port, interface: target.interface)
        } else if !wanted && audioTap != nil {
            stopSystemAudio()
            audioLine = ""
        }
    }

    private func updateStats() {
        guard let pipeline = pipelineBox.withLock({ $0 }) else { return }
        let s = pipeline.takeStats()
        let mbps = Double(s.bytes) * 8 / 1_000_000
        let encodeMs = s.frames > 0 ? Double(s.encodeNsSum) / Double(s.frames) / 1_000_000 : 0
        let captureMs = s.captured > 0 ? Double(s.captureDelayNsSum) / Double(s.captured) / 1_000_000 : 0
        let pipelineMs = s.frames > 0 ? Double(s.pipelineNsSum) / Double(s.frames) / 1_000_000 : 0
        var line = String(format: "%d fps · %.1f Mbit/s · Encoder %.1f ms", s.frames, mbps, encodeMs)
        if s.frames > 0 {
            line += String(format: " · capture %.1f ms · to sent %.1f ms", captureMs, pipelineMs)
        }
        if s.skipped > 0 { line += " · \(s.skipped) skipped" }
        if let r = remoteStats, let latency = r.latencyMs {
            line += String(format: " · capture→frame %.1f ms (max %.1f)", latency, r.latencyMaxMs ?? latency)
            if let lost = r.lost, lost > 0 { line += " · \(lost) lost" }
        }
        statsLine = line
        ddLog.notice("Senden: \(line, privacy: .public)")
        // Also into the receiver's log, so a stuttering stream can be diagnosed from either Mac.
        var report = ControlMessage(.stats)
        report.text = "\(detailText()) | \(line)"
        control?.send(report)

        adjustAutoScale(frames: s.frames, encodeMs: encodeMs)
    }

    /// Encoder slower than ~50 fps for 2 s in a row: stream at the next lower scale.
    /// With auto-restore, step back up once the encoder has had clear headroom for the next higher
    /// scale for a while. (The extra screen keeps its Retina resolution; only capture + encode change.)
    private func adjustAutoScale(frames: Int, encodeMs: Double) {
        guard settings.autoReduce else { slowSeconds = 0; fastSeconds = 0; return }
        let measured = frames >= 5

        if measured && encodeMs > Self.slowEncodeMs { slowSeconds += 1 } else { slowSeconds = 0 }
        if slowSeconds >= 2, let lower = StreamQuality.allCases.map(\.scale).filter({ $0 < streamScale - 0.01 }).max() {
            slowSeconds = 0
            fastSeconds = 0
            // Raised again only shortly ago and already too slow: wait longer before the next try.
            if let raised = lastAutoRaise, Date().timeIntervalSince(raised) < Self.restoreFlapWindow {
                restoreDelay = min(restoreDelay * 2, Self.restoreDelayMax)
            }
            lastAutoRaise = nil
            autoScaleCap = lower
            ddLog.notice("Encoder \(encodeMs, privacy: .public) ms, stream reduced to \(lower, privacy: .public)×")
            settingsChanged()
            return
        }

        guard settings.autoRestore, autoScaleCap != nil, streamScale < maxStreamScale - 0.01,
              let higher = StreamQuality.allCases.map(\.scale)
                  .filter({ $0 > streamScale + 0.01 && $0 <= maxStreamScale + 0.01 }).min() else {
            fastSeconds = 0
            return
        }
        guard measured else { return }   // idle screen: no reliable measurement, keep counting later
        // Encoding time grows roughly with the pixel count; require a safety margin on top.
        let predictedMs = encodeMs * (higher / streamScale) * (higher / streamScale)
        if predictedMs < Self.slowEncodeMs * Self.restoreHeadroom { fastSeconds += 1 } else { fastSeconds = 0 }
        if fastSeconds >= restoreDelay {
            fastSeconds = 0
            autoScaleCap = higher >= maxStreamScale - 0.01 ? nil : higher
            lastAutoRaise = Date()
            ddLog.notice("Encoder \(encodeMs, privacy: .public) ms, stream raised back to \(higher, privacy: .public)×")
            settingsChanged()
        }
    }

    private static let slowEncodeMs = 20.0
    /// Step up only if the predicted encode time stays below this fraction of `slowEncodeMs`.
    private static let restoreHeadroom = 0.75
    private static let restoreDelayInitial = 10
    private static let restoreDelayMax = 300
    /// A reduction within this many seconds after a step-up counts as "step-up failed".
    private static let restoreFlapWindow: TimeInterval = 30
}
