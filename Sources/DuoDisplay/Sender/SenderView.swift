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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Button(action: onBack) { Label("Zurück", systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                        .disabled(session.isBusy)
                    Spacer()
                }
                Text("Bildschirm erweitern").font(.title2.bold())

                ThunderboltStatusView(links: session.thunderboltLinks)
                PairingStatusView(pairedName: session.pairedName,
                                  unpairedText: "Beim ersten „Verbinden“ zeigen beide Macs denselben 6-stelligen Code – auf beiden „Koppeln“ klicken. Danach verbindet sich dieses MacBook nur noch mit diesem Mac.",
                                  onForget: { session.forgetPairing() })
                AccessibilityStatusView(granted: session.accessibilityGranted,
                                        text: "Nötig, damit Tastatur und Trackpad des anderen Macs hier tippen, klicken, scrollen und Gesten ausführen können.")

                if session.isConnected { modeBox }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        if session.receivers.isEmpty {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Suche Macs, auf denen DuoDisplay als Bildschirm läuft…")
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 6)
                        }
                        ForEach(session.receivers) { receiverRow($0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(4)
                } label: { Text("Verfügbare Macs") }

                MediaBox(media: session.media, systemAudio: $systemAudio, audioLine: session.audioLine)

                GroupBox {
                    Form {
                        Picker("Der andere Mac steht", selection: $receiverRight) {
                            Text("rechts vom MacBook").tag(true)
                            Text("links vom MacBook").tag(false)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("„Normal nutzen“: Mit der Maus über den Rand des iMac aufs MacBook wechseln", isOn: $edgeSwitch)
                            Text("Schiebe den Zeiger am \(receiverRight ? "linken" : "rechten") Rand des iMac etwas weiter – dann steuern Maus, Trackpad und Tastatur des iMac dieses MacBook. Am \(receiverRight ? "rechten" : "linken") Rand des MacBook geht es zurück. ⌃⌥⌘D auf dem iMac holt die Eingaben jederzeit zurück. Universal Control dafür am besten ausschalten.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Picker("Codec", selection: $codecRaw) {
                                Text("ProRes (Standard, geringste Verzögerung – nur Thunderbolt)").tag(Int(VideoCodec.prores.rawValue))
                                Text("HEVC (wenig Daten, auch ohne Thunderbolt)").tag(Int(VideoCodec.hevc.rawValue))
                                Text("H.264 (für ältere Macs)").tag(Int(VideoCodec.h264.rawValue))
                            }
                            if codecRaw == Int(VideoCodec.prores.rawValue) {
                                Text("Etwa halb so viel Zeit für Kodieren und Dekodieren wie HEVC, jedes Bild steht für sich (kein Warten auf Keyframes). Braucht dafür rund 250–600 Mbit/s. Ohne Thunderbolt oder ohne ProRes-Hardware nimmt DuoDisplay automatisch HEVC. Am besten mit MTU „Jumbo (9000)“ auf beiden Macs.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Picker("Auflösung", selection: $qualityRaw) {
                            ForEach(StreamQuality.allCases) { Text($0.label).tag($0.rawValue) }
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Toggle("Auflösung automatisch reduzieren, wenn der Encoder nicht hinterherkommt", isOn: $autoReduce)
                            Toggle("Danach automatisch wieder erhöhen, sobald genug Reserve da ist", isOn: $autoRestore)
                                .disabled(!autoReduce)
                                .padding(.leading, 20)
                            Text(autoReduce
                                 ? "Der zweite Bildschirm bleibt immer gleich scharf eingerichtet – nur der Videostream wird kleiner."
                                 : "Aus: Die gewählte Auflösung bleibt fest, auch wenn dadurch Bilder ausfallen.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Picker("Bildrate", selection: $fps) {
                            Text("Wie der iMac (empfohlen)").tag(0)
                            Text("120 Hz – doppelte Last für das MacBook").tag(120)
                            Text("60 Hz").tag(60)
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Slider(value: $bitrate, in: 20...400, step: 10) { Text("Bitrate") }
                                .disabled(codecRaw == Int(VideoCodec.prores.rawValue))
                            Text(codecRaw == Int(VideoCodec.prores.rawValue)
                                 ? "Bei ProRes ergibt sich die Datenrate aus dem Bildinhalt (gilt nur, falls HEVC einspringt)"
                                 : "\(Int(bitrate)) Mbit/s – über Thunderbolt sind hohe Werte unproblematisch")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Mauszeiger lokal zeichnen (ohne Video-Verzögerung)", isOn: $localCursor)
                        Toggle("Nur über Thunderbolt verbinden", isOn: $thunderboltOnly)
                    }
                    .padding(4)
                } label: { Text("Einstellungen (gelten sofort)") }
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

                if case .failed(let message) = session.phase {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 640)
    }

    private var modeBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding(get: { session.mode }, set: { session.setMode($0) })) {
                    Text("Als zweiter Bildschirm").tag(LinkMode.display)
                    Text("Normal nutzen").tag(LinkMode.local)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("Umschalten jederzeit mit \(GlobalHotKey.label) – auf beiden Macs. \(GlobalHotKey.pipLabel) zeigt diesen Bildschirm als Bild-in-Bild auf dem iMac.").font(.callout)
                if session.mode == .local && session.edgeActive {
                    Label("Maus und Tastatur des iMac steuern gerade dieses MacBook", systemImage: "cursorarrow.motionlines")
                        .font(.caption).foregroundStyle(.green)
                }
                if session.mode == .display {
                    if !session.detailLine.isEmpty {
                        Text(session.detailLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(session.statsLine.isEmpty ? (session.streaming ? "…" : "Starte Bildschirm…") : session.statsLine)
                        .font(.system(.caption, design: .monospaced))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: { Text("Gekoppelt mit \(session.connectedName ?? "")") }
    }

    @ViewBuilder
    private func receiverRow(_ receiver: SenderSession.Receiver) -> some View {
        let reachable = !thunderboltOnly || receiver.thunderboltInterface != nil
        HStack(spacing: 10) {
            Image(systemName: "display").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(receiver.name).font(.headline)
                if let tb = receiver.thunderboltInterface {
                    Label("Thunderbolt (\(tb.name))", systemImage: "bolt.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Label("Kein Thunderbolt – nur \(receiver.otherInterfaces.joined(separator: ", "))", systemImage: "wifi")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if session.connectedName == receiver.name {
                if session.isConnected {
                    Button("Trennen", role: .destructive) { session.disconnect() }
                } else if case .pairing = session.phase {
                    Text("Code auf beiden Macs bestätigen…").font(.caption).foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                }
            } else {
                Button("Verbinden") { session.connect(to: receiver) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!reachable || session.isBusy)
            }
        }
        .padding(.vertical, 4)
    }
}

struct ThunderboltStatusView: View {
    let links: [NetLink]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: links.isEmpty ? "bolt.slash.fill" : "bolt.fill")
                .foregroundStyle(links.isEmpty ? .orange : .green)
            VStack(alignment: .leading, spacing: 2) {
                if links.isEmpty {
                    Text("Keine Thunderbolt-Verbindung aktiv").font(.subheadline.bold())
                    Text("Verbinde beide Macs mit einem Thunderbolt-Kabel. macOS richtet die „Thunderbolt Bridge“ automatisch ein.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Thunderbolt verbunden").font(.subheadline.bold())
                    ForEach(links) { link in
                        Text(link.summary).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    if links.allSatisfy({ $0.mtu < 9000 }) {
                        Text("Tipp: MTU auf beiden Macs auf „Jumbo (9000)“ stellen → weniger Pakete, noch geringere Latenz.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

/// Sound to the iMac, and the iMac camera / microphone as devices on this Mac.
struct MediaBox: View {
    @ObservedObject var media: MediaHub
    @Binding var systemAudio: Bool
    let audioLine: String

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Toggle("Ton im Bildschirm-Modus über den iMac abspielen", isOn: $systemAudio)
                    Text(audioLine.isEmpty ? "Das MacBook ist dann stumm, alles klingt aus den iMac-Lautsprechern. Braucht die Freigabe „Bildschirm- & Systemaudioaufnahme“."
                                           : audioLine)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                deviceRow(icon: "web.camera", title: "iMac-Kamera",
                          state: media.cameraInstalled
                              ? (media.cameraInUse ? (media.cameraReceiving ? "wird genutzt – Bild kommt vom iMac" : "wird genutzt – warte auf den iMac…")
                                                   : "bereit – erscheint in FaceTime, Zoom & Co. als „iMac-Kamera (DuoDisplay)“")
                              : "nicht aktiviert",
                          ok: media.cameraInstalled,
                          message: media.cameraMessage) {
                    if !media.cameraInstalled {
                        Button("Kamera-Erweiterung aktivieren…") { media.activateCameraExtension() }
                    }
                }

                deviceRow(icon: "mic", title: "iMac-Mikrofon",
                          state: media.micInstalled
                              ? (media.micInUse ? (media.micReceiving ? "wird genutzt – Ton kommt vom iMac" : "wird genutzt – warte auf den iMac…")
                                                : "bereit – als „iMac-Mikrofon (DuoDisplay)“ auswählbar")
                              : "nicht installiert",
                          ok: media.micInstalled,
                          message: media.micMessage) {
                    if media.installingMic {
                        ProgressView().controlSize(.small)
                    } else if !media.micInstalled || media.micNeedsUpdate {
                        Button(media.micInstalled ? "Aktualisieren…" : "Installieren…") { media.installMic() }
                    }
                }

                if let problem = media.remoteProblem {
                    Label("iMac: \(problem)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("Kamera und Mikrofon des iMac laufen nur, solange eine App hier sie benutzt.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: { Text("Ton, Kamera & Mikrofon") }
    }

    private func deviceRow<Actions: View>(icon: String, title: String, state: String, ok: Bool, message: String?,
                                          @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(ok ? .green : .secondary).frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.bold())
                Text(state).font(.caption).foregroundStyle(.secondary)
                if let message {
                    Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            actions().controlSize(.small)
        }
    }
}
