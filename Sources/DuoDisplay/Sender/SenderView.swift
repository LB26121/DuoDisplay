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
        guard let name = connectedName else { return "Nicht verbunden" }
        if case .pairing = phase { return "Code auf beiden Macs bestätigen…" }
        if !isConnected { return "Verbinde mit \(name)…" }
        return mode == .display ? "\(name) ist zweiter Bildschirm" : "\(name) wird normal genutzt"
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
                       title: "Bildschirm erweitern",
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
                    unpairedText: "Beim ersten „Verbinden“ zeigen beide Macs denselben 6-stelligen Code – auf beiden „Koppeln“ klicken. Danach verbindet sich dieses MacBook nur noch mit diesem Mac.",
                    accessibilityGranted: session.accessibilityGranted,
                    accessibilityText: "Nötig, damit Tastatur und Trackpad des anderen Macs hier tippen, klicken, scrollen und Gesten ausführen können.",
                    onForget: { session.forgetPairing() })
                MediaSection(media: session.media, systemAudio: $systemAudio, audioLine: session.audioLine)
                arrangementSection
                qualitySection
                advancedSection
                RoleSection(symbol: "macbook", title: "Bildschirm erweitern",
                            detail: "Dieser Mac bekommt den zusätzlichen Bildschirm.",
                            disabledReason: session.isBusy ? "Zum Ändern zuerst die Verbindung trennen." : nil,
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
            Picker("Modus", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                Text("Zweiter Bildschirm").tag(LinkMode.display)
                Text("Normal nutzen").tag(LinkMode.local)
            }
            .pickerStyle(.segmented)

            if session.mode == .local && session.edgeActive {
                Label("Maus und Tastatur des iMac steuern gerade dieses MacBook", systemImage: "cursorarrow.motionlines")
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
                            Text(session.streaming ? "Messe…" : "Starte Bildschirm…")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        StatsText(text: session.statsLine)
                    }
                }
                .transition(.opacity)
            }
        } header: {
            Text("Gekoppelt mit \(session.connectedName ?? "")")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                ShortcutHint(text: "Umschalten jederzeit mit", keys: GlobalHotKey.label, trailing: "– auf beiden Macs.")
                ShortcutHint(text: "Bild-in-Bild auf dem iMac:", keys: GlobalHotKey.pipLabel)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var receiversSection: some View {
        Section("Verfügbare Macs") {
            if case .failed(let message) = session.phase {
                NoticeRow(text: message, tone: .error)
            }
            if session.receivers.isEmpty {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Suche Macs, auf denen DuoDisplay als Bildschirm läuft…")
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
                Text("Links").tag(false)
                Text("Rechts").tag(true)
            } label: {
                Text("Der iMac steht")
                Text("vom MacBook aus gesehen")
            }
            .pickerStyle(.segmented)
            .fixedSize()

            Toggle(isOn: $edgeSwitch) {
                Text("Über den Bildschirmrand wechseln")
                Text("Im Modus „Normal nutzen“: Zeiger am \(receiverRight ? "linken" : "rechten") Rand des iMac weiterschieben – dann steuern Maus, Trackpad und Tastatur des iMac dieses MacBook. Am \(receiverRight ? "rechten" : "linken") Rand des MacBook geht es zurück, \(GlobalHotKey.label) auf dem iMac holt die Eingaben jederzeit zurück. Universal Control dafür am besten ausschalten.")
            }
        } header: {
            Text("Anordnung & Steuerung")
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
                Text("Auflösung")
                Text(Self.qualityDescription(StreamQuality(rawValue: qualityRaw) ?? .retina))
            }

            Toggle(isOn: $autoReduce) {
                Text("Bei Überlastung automatisch reduzieren")
                Text(autoReduce
                     ? "Wenn der Encoder nicht hinterherkommt, wird nur der Videostream kleiner – der zweite Bildschirm bleibt gleich scharf eingerichtet."
                     : "Die gewählte Auflösung bleibt fest, auch wenn dadurch Bilder ausfallen.")
            }
            Toggle(isOn: $autoRestore) {
                Text("Danach wieder erhöhen")
                Text("Sobald genug Reserve da ist.")
            }
            .disabled(!autoReduce)

            Picker(selection: $fps) {
                Text("Wie der iMac").tag(0)
                Text("120 Hz").tag(120)
                Text("60 Hz").tag(60)
            } label: {
                Text("Bildrate")
                Text(fps == 120 ? "Doppelte Last für das MacBook." : (fps == 0 ? "Empfohlen – folgt der Bildwiederholrate des iMac." : "Feste 60 Bilder pro Sekunde."))
            }
        } header: {
            Text("Bildqualität")
        } footer: {
            Text("Änderungen gelten sofort. Der Stream startet dabei kurz neu, der zweite Bildschirm und seine Fenster bleiben, wo sie sind.")
                .footerText()
        }
    }

    private var advancedSection: some View {
        Section("Erweitert") {
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
                     ? "Bei ProRes ergibt sich die Datenrate aus dem Bildinhalt – gilt nur, falls HEVC einspringt."
                     : "Über Thunderbolt sind hohe Werte unproblematisch.")
            }
            Toggle(isOn: $localCursor) {
                Text("Mauszeiger lokal zeichnen")
                Text("Der Zeiger erscheint ohne Video-Verzögerung.")
            }
            Toggle(isOn: $thunderboltOnly) {
                Text("Nur über Thunderbolt verbinden")
                Text("Macs, die nur per WLAN oder Ethernet erreichbar sind, lassen sich dann nicht verbinden.")
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
                    Label("Kein Thunderbolt – nur \(receiver.otherInterfaces.joined(separator: ", "))", systemImage: "wifi")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            Group {
                if session.connectedName == receiver.name {
                    if session.isConnected {
                        Button("Trennen") { session.disconnect() }
                    } else if case .pairing = session.phase {
                        Text("Code bestätigen…").font(.callout).foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.small)
                    }
                } else {
                    Button("Verbinden") { session.connect(to: receiver) }
                        .buttonStyle(.borderedProminent)
                        .disabled(!reachable || session.isBusy)
                        .help(reachable ? "Mit \(receiver.name) verbinden" : "Nur über Thunderbolt erlaubt (siehe „Erweitert“)")
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
            return "Geringste Verzögerung: etwa halb so viel Zeit fürs Kodieren wie HEVC, jedes Bild steht für sich. Braucht rund 250–600 Mbit/s – ohne Thunderbolt oder ProRes-Hardware nimmt DuoDisplay automatisch HEVC. Am besten mit MTU „Jumbo (9000)“ auf beiden Macs."
        case .hevc:
            return "Wenig Daten, funktioniert auch ohne Thunderbolt."
        case .h264:
            return "Für ältere Macs."
        }
    }

    private static func shortName(_ quality: StreamQuality) -> String {
        switch quality {
        case .retina: return "Retina (2×)"
        case .balanced: return "Ausgewogen (1,5×)"
        case .fast: return "Schnell (1×)"
        }
    }

    private static func qualityDescription(_ quality: StreamQuality) -> String {
        switch quality {
        case .retina: return "Volle Retina-Pixel – gestochen scharf."
        case .balanced: return "Retina-Oberfläche, gestreamt mit 1,5× – ca. 3 ms schneller."
        case .fast: return "Ohne HiDPI – minimale Latenz."
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
                Text("Ton über den iMac abspielen")
                Text(audioLine.isEmpty
                     ? "Im Bildschirm-Modus ist das MacBook dann stumm, alles klingt aus den iMac-Lautsprechern. Braucht die Freigabe „Bildschirm- & Systemaudioaufnahme“."
                     : audioLine)
            }

            StatusRow(symbol: "web.camera.fill", color: cameraColor, title: "iMac-Kamera",
                      detail: media.cameraInstalled
                          ? (media.cameraInUse ? (media.cameraReceiving ? "Wird genutzt – Bild kommt vom iMac" : "Wird genutzt – warte auf den iMac…")
                                               : "Bereit – in FaceTime, Zoom & Co. als „iMac-Kamera (DuoDisplay)“")
                          : "Nicht aktiviert",
                      warning: media.cameraMessage) {
                if !media.cameraInstalled {
                    Button("Aktivieren…") { media.activateCameraExtension() }
                }
            }

            StatusRow(symbol: "mic.fill", color: micColor, title: "iMac-Mikrofon",
                      detail: media.micInstalled
                          ? (media.micInUse ? (media.micReceiving ? "Wird genutzt – Ton kommt vom iMac" : "Wird genutzt – warte auf den iMac…")
                                            : "Bereit – als „iMac-Mikrofon (DuoDisplay)“ auswählbar")
                          : "Nicht installiert",
                      warning: media.micMessage) {
                if media.installingMic {
                    ProgressView().controlSize(.small)
                } else if !media.micInstalled || media.micNeedsUpdate {
                    Button(media.micInstalled ? "Aktualisieren…" : "Installieren…") { media.installMic() }
                }
            }

            if let problem = media.remoteProblem {
                NoticeRow(text: "iMac: \(problem)")
            }
        } header: {
            Text("Ton, Kamera & Mikrofon")
        } footer: {
            Text("Kamera und Mikrofon des iMac laufen nur, solange eine App auf diesem Mac sie benutzt.")
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
