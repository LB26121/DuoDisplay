import SwiftUI
import AVFoundation

struct ReceiverView: View {
    @ObservedObject var service: ReceiverService
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Button(action: onBack) { Label("Zurück", systemImage: "chevron.left") }
                    .buttonStyle(.borderless)
                Spacer()
            }
            HStack(spacing: 12) {
                Image(systemName: "display").font(.system(size: 34))
                VStack(alignment: .leading, spacing: 2) {
                    Text("„\(service.name)“ als Bildschirm").font(.title2.bold())
                    Text(service.status).foregroundStyle(.secondary)
                }
            }

            ThunderboltStatusView(links: service.thunderboltLinks)
            PairingStatusView(pairedName: service.pairedName,
                              unpairedText: "Auf dem MacBook „Verbinden“ klicken. Dann zeigen beide Macs denselben 6-stelligen Code – auf beiden „Koppeln“ klicken.",
                              onForget: { service.forgetPairing() })
            AccessibilityStatusView(granted: service.accessibilityGranted,
                                    text: "Nötig, damit Tastatur und Trackpad dieses Macs das MacBook steuern – im Bildschirm-Modus und über den Bildschirmrand.")

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    if service.isConnected {
                        Picker("", selection: Binding(
                            get: { service.mode },
                            set: { if $0 != service.mode { service.requestToggle() } })) {
                            Text("Als Bildschirm des MacBook").tag(LinkMode.display)
                            Text("Normal nutzen").tag(LinkMode.local)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        Text("Umschalten jederzeit mit \(GlobalHotKey.label) – auf beiden Macs.")
                            .font(.callout)
                        if service.mode == .local {
                            edgeLine
                            Label(service.pipShowing
                                  ? "Bild-in-Bild des MacBook ist offen. Zeiger ins Bild schieben (von jeder Seite) → Maus und Tastatur steuern das MacBook; über einen Rand des MacBook-Bildschirms wieder hinaus. Schließen: \(GlobalHotKey.pipLabel)."
                                  : "\(GlobalHotKey.pipLabel) zeigt den Bildschirm des MacBook als Bild-in-Bild.",
                                  systemImage: "pip")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let problem = service.pipProblem {
                            Label(problem, systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !service.inputForwarding {
                            Text("Ohne Bedienungshilfen-Freigabe wird der Bildschirm angezeigt, Eingaben werden aber nicht weitergeleitet.")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Toggle("Bild mit V-Sync zeigen (keine Risslinien beim Scrollen)", isOn: $service.vsync)
                        Text(service.vsync
                             ? "Jedes Bild wird erst zum nächsten Bildaufbau des iMac gezeigt – ganz, aber im Schnitt ~8 ms später."
                             : "Bilder erscheinen sofort – minimal schneller, aber bei schnellen Bewegungen mit waagrechten Risslinien.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if !service.statsLine.isEmpty && service.mode == .display {
                            Text(service.statsLine).font(.system(.caption, design: .monospaced))
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Warte auf das MacBook. Dort DuoDisplay öffnen → „Bildschirm erweitern“ → Verbinden. Danach verbindet es sich automatisch.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: { Text("Modus") }

            ReceiverMediaBox(media: service.media)

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(minWidth: 540, minHeight: 620)
    }

    @ViewBuilder
    private var edgeLine: some View {
        if service.edgeActive {
            Label("Maus und Tastatur steuern gerade das MacBook. Zurück: Zeiger über den Rand des MacBook schieben oder \(GlobalHotKey.label).",
                  systemImage: "cursorarrow.motionlines")
                .font(.caption).foregroundStyle(.green)
                .fixedSize(horizontal: false, vertical: true)
        } else if let edge = service.peerEdge {
            Label("Zeiger am \(edge == .left ? "linken" : "rechten") Rand weiterschieben → Maus und Tastatur steuern das MacBook.",
                  systemImage: edge == .left ? "arrow.left.to.line" : "arrow.right.to.line")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Wechsel per Bildschirmrand ist auf dem MacBook ausgeschaltet (oder dort fehlt die Bedienungshilfen-Freigabe).")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Which Mac this one is paired with (only that one can connect).
struct PairingStatusView: View {
    let pairedName: String?
    let unpairedText: String
    let onForget: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: pairedName == nil ? "lock.open" : "lock.fill")
                .foregroundStyle(pairedName == nil ? .orange : .green)
            VStack(alignment: .leading, spacing: 4) {
                if let pairedName {
                    Text("Gekoppelt mit „\(pairedName)“").font(.subheadline.bold())
                    Text("Nur dieser Mac kann sich verbinden. Tastatur- und Mausdaten gehen verschlüsselt über die Leitung.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Kopplung aufheben", role: .destructive, action: onForget).controlSize(.small)
                } else {
                    Text("Noch nicht gekoppelt").font(.subheadline.bold())
                    Text(unpairedText).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

struct AccessibilityStatusView: View {
    let granted: Bool
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: granted ? "keyboard.fill" : "keyboard.badge.exclamationmark")
                .foregroundStyle(granted ? .green : .orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(granted ? "Bedienungshilfen: erlaubt" : "Bedienungshilfen: nicht erlaubt").font(.subheadline.bold())
                Text(text).font(.caption).foregroundStyle(.secondary)
                if !granted {
                    HStack {
                        Button("Erlauben…") { Permissions.requestAccessibility() }
                        Button("Einstellungen öffnen") { Permissions.openAccessibilitySettings() }
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
    }
}

/// Camera + microphone of this Mac for the MacBook.
struct ReceiverMediaBox: View {
    @ObservedObject var media: MediaProvider

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("Kamera und Mikrofon dem MacBook bereitstellen", isOn: $media.enabled)
                Text("Auf dem MacBook erscheinen sie als „iMac-Kamera (DuoDisplay)“ und „iMac-Mikrofon (DuoDisplay)“. Sie laufen nur, solange eine App dort sie benutzt. Der Ton des MacBook kommt im Bildschirm-Modus aus den Lautsprechern dieses Macs.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 16) {
                    permission(.video, label: "Kamera", active: media.cameraActive)
                    permission(.audio, label: "Mikrofon", active: media.micActive)
                }
                .id(media.permissionTick)
                if let problem = media.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: { Text("Kamera & Mikrofon für das MacBook") }
    }

    @ViewBuilder
    private func permission(_ type: AVMediaType, label: String, active: Bool) -> some View {
        let status = MediaPermissions.status(type)
        HStack(spacing: 6) {
            Image(systemName: active ? "record.circle" : (status == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle"))
                .foregroundStyle(active ? .red : (status == .authorized ? .green : .orange))
            Text(active ? "\(label): sendet" : (status == .authorized ? "\(label): erlaubt" : "\(label): nicht erlaubt"))
                .font(.caption)
            if status == .notDetermined {
                Button("Erlauben…") { media.requestPermission(type) }.controlSize(.small)
            } else if status != .authorized {
                Button("Einstellungen") { MediaPermissions.openSettings(type) }.controlSize(.small)
            }
        }
    }
}
