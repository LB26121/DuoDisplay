import SwiftUI
import AVFoundation

extension ReceiverService {
    /// One-line status for the window header and the menu bar menu.
    var statusText: String {
        guard let peer = peerName else { return "Warte auf das MacBook…" }
        if edgeActive { return "Maus und Tastatur steuern \(peer)" }
        return mode == .display ? "Zeigt den Bildschirm von \(peer)" : "Normal – gekoppelt mit \(peer)"
    }
}

struct ReceiverView: View {
    @ObservedObject var service: ReceiverService
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(symbol: "display",
                       title: "„\(service.name)“ als Bildschirm",
                       status: service.isConnected ? service.statusText : service.status,
                       tone: service.isConnected ? .ok : (service.status.hasPrefix("Netzwerkfehler") ? .error : .working))
                .padding(.horizontal, 28)
                .padding(.top, 18)

            Form {
                modeSection
                RequirementsSection(
                    links: service.thunderboltLinks,
                    pairedName: service.pairedName,
                    unpairedText: "Auf dem MacBook „Verbinden“ klicken. Dann zeigen beide Macs denselben 6-stelligen Code – auf beiden „Koppeln“ klicken.",
                    accessibilityGranted: service.accessibilityGranted,
                    accessibilityText: "Nötig, damit Tastatur und Trackpad dieses Macs das MacBook steuern – im Bildschirm-Modus und über den Bildschirmrand.",
                    onForget: { service.forgetPairing() })
                displaySection
                ReceiverMediaSection(media: service.media)
                RoleSection(symbol: "display", title: "Als Bildschirm verwenden",
                            detail: "Dieser Mac zeigt den Bildschirm des MacBook.",
                            onChange: onBack)
            }
            .formStyle(.grouped)
        }
        .designAnimation(value: service.isConnected)
        .designAnimation(value: service.mode)
        .designAnimation(value: service.edgeActive)
        .designAnimation(value: service.pipShowing)
        .frame(minWidth: 580, minHeight: 640)
    }

    private var modeSection: some View {
        Section {
            if service.isConnected {
                Picker("Modus", selection: Binding(
                    get: { service.mode },
                    set: { if $0 != service.mode { service.requestToggle() } })) {
                    Text("Bildschirm des MacBook").tag(LinkMode.display)
                    Text("Normal nutzen").tag(LinkMode.local)
                }
                .pickerStyle(.segmented)

                if service.mode == .local {
                    edgeRow
                    pipRow
                }
                if let problem = service.pipProblem {
                    NoticeRow(text: problem)
                }
                if !service.inputForwarding {
                    NoticeRow(text: "Ohne Bedienungshilfen-Freigabe wird der Bildschirm angezeigt, Eingaben werden aber nicht weitergeleitet.")
                }
            } else {
                HStack(alignment: .top, spacing: 10) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Warte auf das MacBook")
                        Text("Dort DuoDisplay öffnen → „Bildschirm erweitern“ → „Verbinden“. Danach verbindet es sich automatisch.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Modus")
        } footer: {
            if service.isConnected {
                ShortcutHint(text: "Umschalten jederzeit mit", keys: GlobalHotKey.label, trailing: "– auf beiden Macs.")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private var edgeRow: some View {
        if service.edgeActive {
            StatusRow(symbol: "cursorarrow.motionlines", color: .green,
                      title: "Maus und Tastatur steuern gerade das MacBook",
                      detail: "Zurück: Zeiger über den Rand des MacBook schieben oder \(GlobalHotKey.label).")
        } else if let edge = service.peerEdge {
            StatusRow(symbol: edge == .left ? "arrow.left.to.line" : "arrow.right.to.line", color: .blue,
                      title: "Wechsel über den \(edge == .left ? "linken" : "rechten") Rand",
                      detail: "Zeiger dort weiterschieben – dann steuern Maus und Tastatur das MacBook.")
        } else {
            StatusRow(symbol: "rectangle.portrait.slash", color: .gray,
                      title: "Wechsel über den Rand ist aus",
                      detail: "Auf dem MacBook ausgeschaltet – oder dort fehlt die Bedienungshilfen-Freigabe.")
        }
    }

    private var pipRow: some View {
        StatusRow(symbol: "pip.fill", color: service.pipShowing ? .green : .indigo,
                  title: service.pipShowing ? "Bild-in-Bild ist offen" : "Bild-in-Bild",
                  detail: service.pipShowing
                      ? "Zeiger ins Bild schieben (von jeder Seite) – Maus und Tastatur steuern das MacBook; über einen Rand des MacBook-Bildschirms wieder hinaus. Schließen mit \(GlobalHotKey.pipLabel)."
                      : "\(GlobalHotKey.pipLabel) zeigt den Bildschirm des MacBook in einem schwebenden Fenster.") {
            Button(service.pipShowing ? "Schließen" : "Anzeigen") { service.togglePiP() }
        }
    }

    private var displaySection: some View {
        Section("Darstellung") {
            Toggle(isOn: $service.vsync) {
                Text("Mit V-Sync anzeigen")
                Text(service.vsync
                     ? "Keine Risslinien beim Scrollen: Jedes Bild erscheint zum nächsten Bildaufbau des iMac – ganz, aber im Schnitt ~8 ms später."
                     : "Bilder erscheinen sofort – minimal schneller, aber bei schnellen Bewegungen mit waagrechten Risslinien.")
            }
            if service.isConnected && service.mode == .display && !service.statsLine.isEmpty {
                LabeledContent("Messwerte") { StatsText(text: service.statsLine) }
            }
        }
    }
}

/// Camera + microphone of this Mac for the MacBook.
struct ReceiverMediaSection: View {
    @ObservedObject var media: MediaProvider

    var body: some View {
        Section {
            Toggle(isOn: $media.enabled) {
                Text("Kamera und Mikrofon bereitstellen")
                Text("Auf dem MacBook erscheinen sie als „iMac-Kamera (DuoDisplay)“ und „iMac-Mikrofon (DuoDisplay)“ und laufen nur, solange eine App dort sie benutzt.")
            }
            Group {
                permissionRow(.video, label: "Kamera", symbol: "web.camera.fill", activeColor: .green, active: media.cameraActive)
                permissionRow(.audio, label: "Mikrofon", symbol: "mic.fill", activeColor: .orange, active: media.micActive)
            }
            .id(media.permissionTick)
            if let problem = media.problem {
                NoticeRow(text: problem)
            }
        } header: {
            Text("Kamera & Mikrofon für das MacBook")
        } footer: {
            Text("Der Ton des MacBook kommt im Bildschirm-Modus aus den Lautsprechern dieses Macs.")
                .footerText()
        }
    }

    /// Colors follow the macOS privacy indicators: camera green, microphone orange while sending.
    @ViewBuilder
    private func permissionRow(_ type: AVMediaType, label: String, symbol: String, activeColor: Color, active: Bool) -> some View {
        let status = MediaPermissions.status(type)
        let allowed = status == .authorized
        StatusRow(symbol: symbol,
                  color: active ? activeColor : (allowed ? .blue : .gray),
                  title: label,
                  detail: active ? "Sendet gerade ans MacBook" : (allowed ? "Zugriff erlaubt" : "Zugriff nicht erlaubt")) {
            if status == .notDetermined {
                Button("Erlauben…") { media.requestPermission(type) }
                    .buttonStyle(.borderedProminent)
            } else if !allowed {
                Button("Einstellungen öffnen") { MediaPermissions.openSettings(type) }
            }
        }
    }
}
