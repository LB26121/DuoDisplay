import SwiftUI

struct DuoDisplayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = AppModel.shared

    var body: some Scene {
        // The menu bar item comes first, so SwiftUI does not open the window at launch:
        // the app starts quietly in the menu bar (AppDelegate opens the window on first use).
        MenuBarExtra {
            MenuContent(model: model)
        } label: {
            MenuBarLabel(model: model)
        }

        Window("DuoDisplay", id: "main") {
            RootView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}

/// Menu bar icon. It exists for the app's whole lifetime, so it also hands the
/// SwiftUI "open window" action to DockPresence (Dock click, second launch from Finder).
struct MenuBarLabel: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(systemName: model.menuBarSymbol)
            .onAppear { DockPresence.shared.openWindowAction = { openWindow(id: "main") } }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.launch()
        DockPresence.shared.start()
        DispatchQueue.main.async {
            if AppModel.shared.role.isEmpty {
                DockPresence.shared.showMainWindow()   // first launch: choose the mode
            } else {
                DockPresence.shared.closeMainWindowAtLaunch()   // e.g. restored by macOS
            }
        }
    }

    /// Keeps running in the menu bar so the pairing and ⌃⌥⌘D keep working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Opened again from Finder/Launchpad/Spotlight while running: show the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        DockPresence.shared.showMainWindow()
        return false
    }
}

/// App-wide state: the chosen role and its long-lived session (independent of any window).
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var role: String {
        didSet {
            UserDefaults.standard.set(role, forKey: "mode")
            activateRole()
        }
    }

    let sender = SenderSession()
    let receiver = ReceiverService()
    private var hotKey: GlobalHotKey?
    private var observers: [Any] = []

    private init() {
        SenderDefaults.register()
        role = UserDefaults.standard.string(forKey: "mode") ?? ""
        sender.settingsProvider = { SenderDefaults.current }
    }

    func launch() {
        let hotKey = GlobalHotKey()
        hotKey.action = { [weak self] in self?.toggle() }
        hotKey.pipAction = { [weak self] in self?.togglePiP() }
        self.hotKey = hotKey
        // Re-publish child changes so the menu bar icon/menu update.
        observers = [sender.objectWillChange.sink { [weak self] in self?.objectWillChange.send() },
                     receiver.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }]
        activateRole()
    }

    private func activateRole() {
        switch role {
        case "sender":
            receiver.stop()
            sender.start()
        case "receiver":
            sender.stopAll()
            receiver.start()
        default:
            sender.stopAll()
            receiver.stop()
        }
    }

    func toggle() {
        switch role {
        case "sender": sender.toggleMode()
        case "receiver": receiver.requestToggle()
        default: break
        }
    }

    /// ⌃⌥⌘P: the MacBook's screen as picture-in-picture on the iMac.
    func togglePiP() {
        switch role {
        case "sender": sender.requestPiPToggle()
        case "receiver": receiver.togglePiP()
        default: break
        }
    }

    var isConnected: Bool {
        role == "sender" ? sender.isConnected : (role == "receiver" ? receiver.isConnected : false)
    }

    var currentMode: LinkMode {
        role == "sender" ? sender.mode : receiver.mode
    }

    var menuBarSymbol: String {
        guard isConnected else { return "display.trianglebadge.exclamationmark" }
        return currentMode == .display ? "display.2" : "display"
    }

    var statusText: String {
        switch role {
        case "sender":
            guard let name = sender.connectedName else { return "Nicht verbunden" }
            if !sender.isConnected { return "Verbinde mit \(name)…" }
            return sender.mode == .display ? "\(name) ist zweiter Bildschirm" : "\(name) wird normal genutzt"
        case "receiver":
            guard let peer = receiver.peerName else { return "Warte auf das MacBook…" }
            if receiver.edgeActive { return "Maus und Tastatur steuern \(peer)" }
            return receiver.mode == .display ? "Bildschirm von \(peer)" : "Normal – gekoppelt mit \(peer)"
        default:
            return "Kein Modus gewählt"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.statusText)
        if model.isConnected {
            Button(model.currentMode == .display ? "Normal nutzen  (\(GlobalHotKey.label))"
                                                 : "Als zweiten Bildschirm nutzen  (\(GlobalHotKey.label))") {
                model.toggle()
            }
            Button("Bild-in-Bild des MacBook ein/aus  (\(GlobalHotKey.pipLabel))") { model.togglePiP() }
        }
        Divider()
        Button("DuoDisplay-Fenster öffnen") { DockPresence.shared.showMainWindow() }
        Button("Beenden") { NSApp.terminate(nil) }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        switch model.role {
        case "sender":
            SenderView(session: model.sender, onBack: { model.role = "" })
        case "receiver":
            ReceiverView(service: model.receiver, onBack: { model.role = "" })
        default:
            ModePicker(mode: $model.role)
        }
    }
}

struct ModePicker: View {
    @Binding var mode: String

    var body: some View {
        VStack(spacing: 22) {
            Text("DuoDisplay").font(.largeTitle.bold())
            Text("Ein Mac als zweiter Bildschirm des anderen – per Thunderbolt, mit minimaler Latenz.\nUmschalten jederzeit mit \(GlobalHotKey.label).")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            HStack(spacing: 18) {
                card(icon: "macbook.and.display",
                     title: "Bildschirm erweitern",
                     text: "Für das MacBook: Es bekommt einen zusätzlichen Bildschirm, der auf dem anderen Mac angezeigt wird.",
                     tag: "sender")
                card(icon: "display",
                     title: "Als Bildschirm verwenden",
                     text: "Für den iMac: Er zeigt den Bildschirm des MacBook an – seine Tastatur und sein Trackpad steuern dann das MacBook.",
                     tag: "receiver")
            }
        }
        .padding(36)
        .frame(minWidth: 640, minHeight: 400)
    }

    private func card(icon: String, title: String, text: String, tag: String) -> some View {
        Button { mode = tag } label: {
            VStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 44))
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(22)
            .frame(width: 260, height: 230)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.12)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
