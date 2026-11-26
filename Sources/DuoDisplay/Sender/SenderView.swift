import SwiftUI

/// Persisted sender settings (read by SenderSession through `settingsProvider`).
enum SenderDefaults {
    static func register() {
        UserDefaults.standard.register(defaults: [
            "sender.codec3": Int(VideoCodec.prores.rawValue),
            "sender.fps3": 0,
            "sender.bitrate": 150.0,
            "sender.quality": StreamQuality.retina.rawValue,
            "sender.tbOnly": true,
            "sender.receiverRight": true,
            "sender.localCursor": true,
            "sender.systemAudio": true,
            "sender.autoReduce": true,
            "sender.autoRestore": true,
            "sender.edgeSwitch": true,
        ])
    }

    static var current: StreamSettings {
        let d = UserDefaults.standard
        return StreamSettings(
            codec: VideoCodec(rawValue: UInt8(d.integer(forKey: "sender.codec3"))) ?? .prores,
            fps: d.integer(forKey: "sender.fps3"),
            bitrateMbps: d.double(forKey: "sender.bitrate"),
            quality: StreamQuality(rawValue: d.integer(forKey: "sender.quality")) ?? .retina,
            thunderboltOnly: d.bool(forKey: "sender.tbOnly"),
            receiverOnRight: d.bool(forKey: "sender.receiverRight"),
            localCursor: d.bool(forKey: "sender.localCursor"),
            systemAudio: d.bool(forKey: "sender.systemAudio"),
            autoReduce: d.bool(forKey: "sender.autoReduce"),
            autoRestore: d.bool(forKey: "sender.autoRestore"),
            edgeSwitch: d.bool(forKey: "sender.edgeSwitch"))
    }
}


extension SenderSession {
    /// One-line status for the window header and the menu bar menu.
    var statusText: String {
        guard let name = connectedName else { return "Not connected" }
        if case .pairing = phase { return "Confirm the code on both Macs…" }
        if !isConnected { return "Connecting to \(name)…" }
        return mode == .display ? "\(name) is a second display" : "\(name) in normal use"
    }

    var statusTone: StatusTone {
        if case .failed = phase { return .error }
        if isConnected { return .ok }
        return isBusy ? .working : .idle
    }
}

struct SenderView: View {
    @ObservedObject var session: SenderSession
    @AppStorage("sender.codec3") private var codecRaw = Int(VideoCodec.prores.rawValue)
    @AppStorage("sender.fps3") private var fps = 0
    @AppStorage("sender.bitrate") private var bitrate = 150.0
    @AppStorage("sender.quality") private var qualityRaw = StreamQuality.retina.rawValue
    @AppStorage("sender.tbOnly") private var thunderboltOnly = true
    @AppStorage("sender.receiverRight") private var receiverRight = true
    @AppStorage("sender.localCursor") private var localCursor = true
    @AppStorage("sender.systemAudio") private var systemAudio = true
    @AppStorage("sender.autoReduce") private var autoReduce = true
    @AppStorage("sender.autoRestore") private var autoRestore = true
    @AppStorage("sender.edgeSwitch") private var edgeSwitch = true

    let onBack: () -> Void

    private var isProRes: Bool { codecRaw == Int(VideoCodec.prores.rawValue) }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "macbook",
                       title: "Extend Display",
                       status: session.statusText,
                       tone: session.statusTone)
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Form {
                if session.isConnected { modeSection }
                receiversSection
                RequirementsSection(
                    links: session.thunderboltLinks,
                    pairedName: session.pairedName,
                    unpairedText: "On the first “Connect”, both Macs show the same 6-digit code. Click “Pair” on both. This MacBook then connects only to that Mac.",
                    accessibilityGranted: session.accessibilityGranted,
                    accessibilityText: "Lets the other Mac’s keyboard and trackpad type, click, scroll and use gestures here.",
                    onForget: { session.forgetPairing() })
                MediaSection(media: session.media, systemAudio: $systemAudio, audioLine: session.audioLine)
                arrangementSection
                qualitySection
                advancedSection
                RoleSection(symbol: "macbook", title: "Extend Display",
                            detail: "This Mac gets the extra display.",
                            disabledReason: session.isBusy ? "Disconnect first to change this." : nil,
                            onChange: onBack)
            }
            .formStyle(.grouped)
        }
        .designAnimation(value: session.isConnected)
        .designAnimation(value: session.mode)
        .designAnimation(value: session.receivers)
        .frame(minWidth: 600, minHeight: 680)
        .onChange(of: qualityRaw) { session.settingsChanged(qualityChanged: true) }
        .onChange(of: codecRaw) { session.settingsChanged() }
        .onChange(of: fps) { session.settingsChanged() }
        .onChange(of: bitrate) { session.settingsChanged() }
        .onChange(of: localCursor) { session.settingsChanged() }
        .onChange(of: receiverRight) { session.settingsChanged(); session.sendEdgeConfig() }
        .onChange(of: edgeSwitch) { session.sendEdgeConfig() }
        .onChange(of: autoReduce) { session.autoScaleSettingsChanged() }
        .onChange(of: autoRestore) { session.autoScaleSettingsChanged() }
        .onChange(of: systemAudio) { session.systemAudioChanged() }
    }

    // MARK: Sections

    private var modeSection: some View {
        Section {
            Picker("Mode", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                Text("Second Display").tag(LinkMode.display)
                Text("Normal Use").tag(LinkMode.local)
            }
            .pickerStyle(.segmented)

            if session.mode == .local && session.edgeActive {
                Label("The iMac’s mouse and keyboard are controlling this MacBook", systemImage: "cursorarrow.motionlines")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            }
            if session.mode == .display {
                VStack(alignment: .leading, spacing: 4) {
                    if !session.detailLine.isEmpty {
                        Text(session.detailLine).font(.callout).foregroundStyle(.secondary)
                    }
                    if session.statsLine.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(session.streaming ? "Measuring…" : "Starting display…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        StatsText(text: session.statsLine)
                    }
                }
                .transition(.opacity)
            }
        } header: {
            Text("Paired with \(session.connectedName ?? "")")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ShortcutHint(text: "Switch anytime with", keys: GlobalHotKey.label, trailing: "on either Mac.")
                ShortcutHint(text: "Picture-in-picture on the iMac:", keys: GlobalHotKey.pipLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var receiversSection: some View {
        Section("Available Macs") {
            if case .failed(let message) = session.phase {
                NoticeRow(text: message, tone: .error)
            }
            if session.receivers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Looking for Macs running DuoDisplay as a display…")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            ForEach(session.receivers) { receiverRow($0) }
        }
    }

    private var arrangementSection: some View {
        Section {
            Picker(selection: $receiverRight) {
                Text("Left").tag(false)
                Text("Right").tag(true)
            } label: {
                Text("iMac position")
                Text("Seen from the MacBook")
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Toggle(isOn: $edgeSwitch) {
                Text("Switch at the screen edge")
                Text("In Normal Use, push the pointer past the iMac’s \(receiverRight ? "left" : "right") edge to control this MacBook. Go back via the MacBook’s \(receiverRight ? "right" : "left") edge or \(GlobalHotKey.label) on the iMac. Best with Universal Control off.")
            }
        } header: {
            Text("Arrangement & Control")
        }
    }

    private var qualitySection: some View {
        Section {
            Picker(selection: $codecRaw) {
                Text("ProRes").tag(Int(VideoCodec.prores.rawValue))
                Text("HEVC").tag(Int(VideoCodec.hevc.rawValue))
                Text("H.264").tag(Int(VideoCodec.h264.rawValue))
            } label: {
                Text("Codec")
                Text(codecDescription)
            }

            Picker(selection: $qualityRaw) {
                ForEach(StreamQuality.allCases) { Text(Self.shortName($0)).tag($0.rawValue) }
            } label: {
                Text("Resolution")
                Text(Self.qualityDescription(StreamQuality(rawValue: qualityRaw) ?? .retina))
            }

            Toggle(isOn: $autoReduce) {
                Text("Reduce automatically when overloaded")
                Text(autoReduce
                     ? "If the encoder can’t keep up, only the video stream gets smaller. The display itself stays sharp."
                     : "The resolution stays fixed, even if frames drop.")
            }
            Toggle(isOn: $autoRestore) {
                Text("Raise again afterwards")
                Text("Once there is enough headroom.")
            }
            .disabled(!autoReduce)

            Picker(selection: $fps) {
                Text("Match iMac").tag(0)
                Text("120 Hz").tag(120)
                Text("60 Hz").tag(60)
            } label: {
                Text("Frame Rate")
                Text(fps == 120 ? "Doubles the MacBook’s workload." : (fps == 0 ? "Recommended. Follows the iMac’s refresh rate." : "Fixed 60 frames per second."))
            }
        } header: {
            Text("Image Quality")
        } footer: {
            Text("Changes apply immediately. The stream restarts briefly; the display and its windows stay put.")
                .footerText()
        }
    }

    private var advancedSection: some View {
        Section("Advanced") {
            LabeledContent {
                HStack(spacing: 10) {
                    Slider(value: $bitrate, in: 20...400, step: 10)
                        .labelsHidden()
                        .frame(minWidth: 140, maxWidth: 220)
                    Text("\(Int(bitrate)) Mbit/s")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 84, alignment: .trailing)
                }
                .disabled(isProRes)
            } label: {
                Text("Bitrate")
                Text(isProRes
                     ? "ProRes sets its own data rate. Only used if HEVC takes over."
                     : "High values are fine over Thunderbolt.")
            }
            Toggle(isOn: $localCursor) {
                Text("Draw pointer locally")
                Text("The pointer moves without video delay.")
            }
            Toggle(isOn: $thunderboltOnly) {
                Text("Connect over Thunderbolt only")
                Text("Macs reachable only via Wi-Fi or Ethernet can’t connect.")
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func receiverRow(_ receiver: SenderSession.Receiver) -> some View {
        let reachable = !thunderboltOnly || receiver.thunderboltInterface != nil
        HStack(spacing: 10) {
            SymbolTile(systemName: "display", color: .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(receiver.name)
                if let tb = receiver.thunderboltInterface {
                    Label("Thunderbolt (\(tb.name))", systemImage: "bolt.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    Label("No Thunderbolt, only \(receiver.otherInterfaces.joined(separator: ", "))", systemImage: "wifi")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Group {
                if session.connectedName == receiver.name {
                    if session.isConnected {
                        Button("Disconnect") { session.disconnect() }
                    } else if case .pairing = session.phase {
                        Text("Confirm code…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button("Connect") { session.connect(to: receiver) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!reachable || session.isBusy)
                        .help(reachable ? "Connect to \(receiver.name)" : "Thunderbolt only (see Advanced)")
                }
            }
            .transition(.opacity)
        }
        .padding(.vertical, 2)
    }

    // MARK: Texts

    private var codecDescription: String {
        switch VideoCodec(rawValue: UInt8(codecRaw)) ?? .prores {
        case .prores:
            return "Lowest latency: half the encode time of HEVC. Needs ~250–600 Mbit/s; without Thunderbolt or ProRes hardware, DuoDisplay uses HEVC. Best with MTU “Jumbo (9000)” on both Macs."
        case .hevc:
            return "Little data, works without Thunderbolt."
        case .h264:
            return "For older Macs."
        }
    }

    private static func shortName(_ quality: StreamQuality) -> String {
        switch quality {
        case .retina: return "Retina (2×)"
        case .balanced: return "Balanced (1.5×)"
        case .fast: return "Fast (1×)"
        }
    }

    private static func qualityDescription(_ quality: StreamQuality) -> String {
        switch quality {
        case .retina: return "Full Retina pixels, razor sharp."
        case .balanced: return "Retina UI streamed at 1.5×, ~3 ms faster."
        case .fast: return "No HiDPI, minimal latency."
        }
    }
}

/// Sound to the iMac, and the iMac camera / microphone as devices on this Mac.
struct MediaSection: View {
    @ObservedObject var media: MediaHub
    @Binding var systemAudio: Bool
    let audioLine: String

    var body: some View {
        Section {
            Toggle(isOn: $systemAudio) {
                Text("Play sound on the iMac")
                Text(audioLine.isEmpty
                     ? "In Second Display mode the MacBook is muted and sound plays on the iMac. Needs “Screen & System Audio Recording” permission."
                     : audioLine)
            }

            StatusRow(symbol: "web.camera.fill", color: cameraColor, title: "iMac Camera",
                      detail: media.cameraInstalled
                          ? (media.cameraInUse ? (media.cameraReceiving ? "In use, receiving from the iMac" : "In use, waiting for the iMac…")
                                               : "Ready: choose “iMac Camera (DuoDisplay)” in FaceTime, Zoom etc.")
                          : "Not activated",
                      warning: media.cameraMessage) {
                if !media.cameraInstalled {
                    Button("Activate…") { media.activateCameraExtension() }
                }
            }

            StatusRow(symbol: "mic.fill", color: micColor, title: "iMac Microphone",
                      detail: media.micInstalled
                          ? (media.micInUse ? (media.micReceiving ? "In use, receiving from the iMac" : "In use, waiting for the iMac…")
                                            : "Ready: choose “iMac Microphone (DuoDisplay)”")
                          : "Not installed",
                      warning: media.micMessage) {
                if media.installingMic {
                    ProgressView().controlSize(.small)
                } else if !media.micInstalled || media.micNeedsUpdate {
                    Button(media.micInstalled ? "Update…" : "Install…") { media.installMic() }
                }
            }

            if let problem = media.remoteProblem {
                NoticeRow(text: "iMac: \(problem)")
            }
        } header: {
            Text("Sound, Camera & Microphone")
        } footer: {
            Text("The iMac’s camera and microphone only run while an app on this Mac uses them.")
                .footerText()
        }
    }

    /// Same colors as the macOS privacy indicators: camera green, microphone orange while in use.
    private var cameraColor: Color {
        guard media.cameraInstalled else { return .gray }
        return media.cameraInUse ? .green : .blue
    }

    private var micColor: Color {
        guard media.micInstalled else { return .gray }
        return media.micInUse ? .orange : .blue
    }
}
