import AppKit
import SwiftUI
import Network

/// Small floating window "Does the other Mac show the same code?" – used on both Macs and
/// independent of the main window (which may be closed; the app lives in the menu bar).
/// Main thread only.
final class PairingPrompt: NSObject, ObservableObject, NSWindowDelegate {
    @Published private(set) var code = ""
    @Published private(set) var peerName = ""
    @Published private(set) var note: String?
    @Published private(set) var waiting = false

    private var panel: NSPanel?
    private var onConfirm: (() -> Void)?
    private var onCancel: (() -> Void)?
    private var timeout: DispatchWorkItem?

    var isShowing: Bool { panel != nil }

    /// Warning shown with a pairing request that does not come over the Thunderbolt cable –
    /// over Wi-Fi it may come from any device on the network.
    static func notThunderboltNote(_ connection: NWConnection) -> String {
        let interface = connection.currentPath?.availableInterfaces.first
        let via: String
        switch interface?.type {
        case .wifi?: via = "über WLAN"
        case .wiredEthernet?: via = "über Ethernet"
        default: via = "über ein anderes Netzwerk"
        }
        let name = interface.map { " (\($0.name))" } ?? ""
        return "Achtung: Diese Anfrage kommt nicht über das Thunderbolt-Kabel, sondern \(via)\(name). Nur koppeln, wenn du die Verbindung gerade selbst gestartet hast."
    }

    func show(code: String, peerName: String, note: String?, onConfirm: @escaping () -> Void, onCancel: @escaping () -> Void) {
        close()
        self.code = code
        self.peerName = peerName
        self.note = note
        waiting = false
        self.onConfirm = onConfirm
        self.onCancel = onCancel

        let hosting = NSHostingView(rootView: PairingPromptView(prompt: self))
        let panel = NSPanel(contentRect: CGRect(origin: .zero, size: hosting.fittingSize),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "DuoDisplay – Macs koppeln"
        // Modern dialog look: content runs under a transparent title bar, no separator line.
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.titlebarSeparatorStyle = .none
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.contentView = hosting
        panel.delegate = self
        panel.center()
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)

        let work = DispatchWorkItem { [weak self] in self?.cancel() }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: work)
    }

    func confirm() {
        guard !waiting else { return }
        waiting = true
        onConfirm?()
    }

    func cancel() {
        let cancel = onCancel
        close()
        cancel?()
    }

    /// Closes without reporting anything (pairing finished or the connection went away).
    func close() {
        timeout?.cancel()
        timeout = nil
        onConfirm = nil
        onCancel = nil
        let panel = self.panel
        self.panel = nil
        panel?.delegate = nil
        panel?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        cancel()   // the user clicked the close button
    }
}

struct PairingPromptView: View {
    @ObservedObject var prompt: PairingPrompt

    var body: some View {
        VStack(spacing: 18) {
            VStack(spacing: 10) {
                SymbolTile(systemName: "lock.shield.fill", color: .blue, size: 52)
                Text("Mit „\(prompt.peerName)“ koppeln?")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
            }

            CodeDigits(code: prompt.code)

            Text("Nur bestätigen, wenn der andere Mac genau diesen Code zeigt und du dort gerade die Verbindung gestartet hast. Danach auf beiden Macs „Koppeln“ klicken.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let note = prompt.note {
                Label {
                    Text(note).fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .font(.callout)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.orange.opacity(0.12)))
            }

            Group {
                if prompt.waiting {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Warte auf den anderen Mac…").foregroundStyle(.secondary)
                    }
                    .frame(height: 28)
                } else {
                    // "Koppeln" deliberately has no Return shortcut: pairing should be a conscious click.
                    HStack(spacing: 10) {
                        Button(role: .cancel) { prompt.cancel() } label: {
                            Text("Abbrechen").frame(maxWidth: .infinity)
                        }
                        .keyboardShortcut(.cancelAction)
                        Button { prompt.confirm() } label: {
                            Text("Koppeln").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                }
            }
        }
        .padding(28)
        .frame(width: 400)
    }
}

/// The 6-digit code as two groups of three key-like boxes, easy to compare at a glance.
private struct CodeDigits: View {
    let code: String

    var body: some View {
        let digits = Array(code)
        HStack(spacing: 14) {
            group(digits.prefix(3))
            group(digits.dropFirst(3))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Code \(digits.map(String.init).joined(separator: " "))")
    }

    private func group(_ slice: ArraySlice<Character>) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(slice.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                    .frame(width: 42, height: 54)
                    .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
