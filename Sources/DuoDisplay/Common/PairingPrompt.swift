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
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "DuoDisplay – Macs koppeln"
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

private struct PairingPromptView: View {
    @ObservedObject var prompt: PairingPrompt

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.shield").font(.system(size: 34)).foregroundStyle(.tint)
            Text("Mit „\(prompt.peerName)“ koppeln?").font(.headline)
            Text(prompt.code)
                .font(.system(size: 40, weight: .semibold, design: .monospaced))
                .textSelection(.disabled)
            Text("Nur bestätigen, wenn der andere Mac genau diesen Code zeigt und du dort gerade die Verbindung gestartet hast. Danach auf beiden Macs „Koppeln“ klicken.")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let note = prompt.note {
                Text(note).font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if prompt.waiting {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Warte auf den anderen Mac…").foregroundStyle(.secondary)
                }
            } else {
                HStack {
                    Button("Abbrechen", role: .cancel) { prompt.cancel() }
                        .keyboardShortcut(.cancelAction)
                    Button("Koppeln") { prompt.confirm() }
                }
            }
        }
        .padding(24)
        .frame(width: 380)
    }
}
