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
        case "sender": return sender.statusText
        case "receiver": return receiver.statusText
        default: return "No role chosen"
        }
    }
}

struct MenuContent: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Section(model.statusText) {
            if model.isConnected {
                Button {
                    model.toggle()
                } label: {
                    Label((model.currentMode == .display ? "Normal Use" : "Use as Second Display")
                              + "  (\(GlobalHotKey.label))",
                          systemImage: model.currentMode == .display ? "display" : "display.2")
                }
                Button {
                    model.togglePiP()
                } label: {
                    Label("Picture-in-Picture  (\(GlobalHotKey.pipLabel))", systemImage: "pip")
                }
            }
        }
        Divider()
        Button("Open DuoDisplay Window…") { DockPresence.shared.showMainWindow() }
        Divider()
        Button("Quit DuoDisplay") { NSApp.terminate(nil) }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.role {
            case "sender":
                SenderView(session: model.sender, onBack: { model.role = "" })
            case "receiver":
                ReceiverView(service: model.receiver, onBack: { model.role = "" })
            default:
                ModePicker(mode: $model.role)
            }
        }
        .transition(.opacity)
        .designAnimation(value: model.role)
    }
}

/// First launch: which Mac is this?
struct ModePicker: View {
    @Binding var mode: String

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 84, height: 84)
                    .accessibilityHidden(true)
                Text("Welcome to DuoDisplay")
                    .font(.largeTitle.weight(.bold))
                    .tracking(-0.4)
                Text("Use one Mac as a second display for another, over Thunderbolt with minimal latency.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            VStack(spacing: 14) {
                Text("What is this Mac for?")
                    .font(.headline)
                HStack(spacing: 16) {
                    ModeCard(symbol: "macbook", color: .blue,
                             device: "On the MacBook",
                             title: "Extend Display",
                             text: "The MacBook gets an extra display, shown on the other Mac.") {
                        mode = "sender"
                    }
                    ModeCard(symbol: "display", color: .indigo,
                             device: "On the iMac",
                             title: "Use as Display",
                             text: "The iMac shows the MacBook’s display, and its keyboard and trackpad control the MacBook.") {
                        mode = "receiver"
                    }
                }
            }

            ShortcutHint(text: "Switch anytime with", keys: GlobalHotKey.label)
        }
        .padding(40)
        .frame(minWidth: 660, minHeight: 520)
    }
}

/// A large, clickable choice card. Highlights on hover, presses in on mouse-down.
private struct ModeCard: View {
    let symbol: String
    let color: Color
    let device: String
    let title: String
    let text: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 12) {
                SymbolTile(systemName: symbol, color: color, size: 56)
                VStack(spacing: 4) {
                    Text(device.uppercased())
                        .font(.caption.weight(.semibold))
                        .tracking(0.6)
                        .foregroundStyle(color)
                    Text(title)
                        .font(.title3.weight(.semibold))
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 24)
            .frame(width: 270, height: 216)
        }
        .buttonStyle(CardButtonStyle(tint: color))
        .accessibilityHint(device)
    }
}

/// Hover flag for the card style (a class: `@State` needs the SwiftUI macro plugin, which the
/// Command Line Tools don't ship).
private final class HoverState: ObservableObject {
    @Published var isHovering = false
}

private struct CardButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        CardBody(configuration: configuration, tint: tint)
    }

    private struct CardBody: View {
        let configuration: Configuration
        let tint: Color
        @StateObject private var hover = HoverState()
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private var hovering: Bool { hover.isHovering }

        var body: some View {
            // Concentric with the window's large Liquid Glass corners.
            let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
            configuration.label
                .contentShape(shape)
                .glassSurface(in: shape, interactive: true)
                .overlay(
                    shape.strokeBorder(tint.opacity(hovering ? 0.9 : 0), lineWidth: 1.5)
                )
                .shadow(color: .black.opacity(hovering ? 0.12 : 0), radius: 14, y: 5)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .animation(reduceMotion ? nil : Design.press(configuration.isPressed), value: configuration.isPressed)
                .animation(reduceMotion ? nil : Design.spring, value: hovering)
                .onHover { hover.isHovering = $0 }
        }
    }
}
