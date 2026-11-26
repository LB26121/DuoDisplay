import SwiftUI
import AppKit

/// The three things both Macs need before anything works: the cable, the pairing and the
/// Accessibility permission. Shown as one "Requirements" section in both mode windows.
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
            Text("Requirements")
        } footer: {
            if allReady {
                Label("All set", systemImage: "checkmark.circle.fill")
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
                Button("Change…", action: onChange)
                    .disabled(disabledReason != nil)
            }
        } header: {
            Text("This Mac’s Role")
        }
    }
}

struct ThunderboltStatusRow: View {
    let links: [NetLink]

    var body: some View {
        if links.isEmpty {
            StatusRow(symbol: "bolt.slash.fill", color: .orange,
                      title: "No Thunderbolt connection",
                      detail: "Connect both Macs with a Thunderbolt cable. macOS sets up the Thunderbolt Bridge automatically.")
        } else {
            HStack(alignment: .center, spacing: 10) {
                SymbolTile(systemName: "bolt.fill", color: .green)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Thunderbolt connected")
                    ForEach(links) { link in
                        Text(link.summary)
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    if links.allSatisfy({ $0.mtu < 9000 }) {
                        Text("Tip: set MTU to “Jumbo (9000)” on both Macs for fewer packets and lower latency.")
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
                      title: "Paired with “\(pairedName)”",
                      detail: "Only this Mac can connect. All traffic is encrypted.") {
                Button("Unpair…") { confirmForget(pairedName) }
            }
        } else {
            StatusRow(symbol: "lock.open.fill", color: .orange,
                      title: "Not paired yet",
                      detail: unpairedText)
        }
    }
}

/// Forgetting the pairing forces a new code comparison on both Macs, so ask first.
private func confirmForgetAlert(_ name: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Unpair from “\(name)”?"
    alert.informativeText = "Both Macs will need to pair again with the 6-digit code."
    let forget = alert.addButton(withTitle: "Unpair")
    forget.hasDestructiveAction = true
    alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
    return alert.runModal() == .alertFirstButtonReturn
}

struct AccessibilityStatusRow: View {
    let granted: Bool
    let text: String

    var body: some View {
        StatusRow(symbol: "keyboard.fill",
                  color: granted ? .green : .orange,
                  title: granted ? "Accessibility allowed" : "Accessibility not allowed",
                  detail: granted ? nil : text) {
            if !granted {
                HStack(spacing: 6) {
                    Button("Open Settings") { Permissions.openAccessibilitySettings() }
                    Button("Allow…") { Permissions.requestAccessibility() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}
