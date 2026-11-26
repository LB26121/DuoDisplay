import SwiftUI
import AppKit

/// The three things both Macs need before anything works: the cable, the pairing and the
/// Accessibility permission. Shown as one "Voraussetzungen" section in both mode windows.
struct RequirementsSection: View {
    let links: [NetLink]
    let pairedName: String?
    let unpairedText: String
    let accessibilityGranted: Bool
    let accessibilityText: String
    let onForget: () -> Void

    private var allReady: Bool { !links.isEmpty && pairedName != nil && accessibilityGranted }

    var body: some View {
        Section {
            ThunderboltStatusRow(links: links)
            PairingStatusRow(pairedName: pairedName, unpairedText: unpairedText, onForget: onForget)
            AccessibilityStatusRow(granted: accessibilityGranted, text: accessibilityText)
        } header: {
            Text("Voraussetzungen")
        } footer: {
            if allReady {
                Label("Alles bereit", systemImage: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .symbolRenderingMode(.multicolor)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// Last section of a mode window: which role this Mac has, and the way back to the mode choice.
/// Deliberately at the bottom and labeled – switching roles is rare.
struct RoleSection: View {
    let symbol: String
    let title: String
    let detail: String
    var disabledReason: String? = nil
    let onChange: () -> Void

    var body: some View {
        Section {
            StatusRow(symbol: symbol, color: .gray, title: title, detail: disabledReason ?? detail) {
                Button("Ändern…", action: onChange)
                    .disabled(disabledReason != nil)
            }
        } header: {
            Text("Modus dieses Macs")
        }
    }
}

struct ThunderboltStatusRow: View {
    let links: [NetLink]

    var body: some View {
        if links.isEmpty {
            StatusRow(symbol: "bolt.slash.fill", color: .orange,
                      title: "Keine Thunderbolt-Verbindung",
                      detail: "Verbinde beide Macs mit einem Thunderbolt-Kabel. macOS richtet die „Thunderbolt Bridge“ automatisch ein.")
        } else {
            HStack(alignment: .center, spacing: 10) {
                SymbolTile(systemName: "bolt.fill", color: .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thunderbolt verbunden")
                    ForEach(links) { link in
                        Text(link.summary)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if links.allSatisfy({ $0.mtu < 9000 }) {
                        Text("Tipp: MTU auf beiden Macs auf „Jumbo (9000)“ stellen – weniger Pakete, noch geringere Latenz.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Which Mac this one is paired with (only that one can connect).
struct PairingStatusRow: View {
    let pairedName: String?
    let unpairedText: String
    let onForget: () -> Void

    private func confirmForget(_ name: String) {
        if confirmForgetAlert(name) { onForget() }
    }

    var body: some View {
        if let pairedName {
            StatusRow(symbol: "lock.fill", color: .green,
                      title: "Gekoppelt mit „\(pairedName)“",
                      detail: "Nur dieser Mac kann sich verbinden. Tastatur- und Mausdaten gehen verschlüsselt über die Leitung.") {
                Button("Aufheben…") { confirmForget(pairedName) }
            }
        } else {
            StatusRow(symbol: "lock.open.fill", color: .orange,
                      title: "Noch nicht gekoppelt",
                      detail: unpairedText)
        }
    }
}

/// Forgetting the pairing forces a new code comparison on both Macs, so ask first.
private func confirmForgetAlert(_ name: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Kopplung mit „\(name)“ aufheben?"
    alert.informativeText = "Danach müssen beide Macs erneut mit dem 6-stelligen Code gekoppelt werden."
    let forget = alert.addButton(withTitle: "Kopplung aufheben")
    forget.hasDestructiveAction = true
    alert.addButton(withTitle: "Abbrechen").keyEquivalent = "\u{1b}"
    return alert.runModal() == .alertFirstButtonReturn
}

struct AccessibilityStatusRow: View {
    let granted: Bool
    let text: String

    var body: some View {
        StatusRow(symbol: "keyboard.fill",
                  color: granted ? .green : .orange,
                  title: granted ? "Bedienungshilfen erlaubt" : "Bedienungshilfen nicht erlaubt",
                  detail: granted ? nil : text) {
            if !granted {
                HStack(spacing: 6) {
                    Button("Einstellungen öffnen") { Permissions.openAccessibilitySettings() }
                    Button("Erlauben…") { Permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
