import AppKit

/// The app normally lives only in the menu bar (Info.plist: LSUIElement). While the DuoDisplay
/// window is open – or minimised into the Dock – it becomes a regular app with a Dock icon and
/// its own menu bar, so the window can be found with ⌘-Tab and the Dock like any other.
final class DockPresence {
    static let shared = DockPresence()

    /// Set by the menu bar label (it lives as long as the app): opens the SwiftUI window
    /// even after it was closed and SwiftUI let go of its NSWindow.
    var openWindowAction: (() -> Void)? {
        didSet {
            if openPending, let openWindowAction {
                openPending = false
                openWindowAction()
            }
        }
    }
    private var openPending = false

    private var observers: [NSObjectProtocol] = []
    private var updateScheduled = false

    /// SwiftUI gives the NSWindow of `Window("DuoDisplay", id: "main")` an identifier starting with "main".
    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main") == true
    }

    private var mainWindows: [NSWindow] { NSApp.windows.filter(Self.isMainWindow) }

    func start() {
        let names: [Notification.Name] = [
            NSWindow.didBecomeKeyNotification,
            NSWindow.didBecomeMainNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
            NSWindow.willCloseNotification,
        ]
        observers = names.map { name in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, Self.isMainWindow(window) else { return }
                self?.scheduleUpdate()
            }
        }
        scheduleUpdate()
    }

    /// Menu bar entry, Dock click or a second launch from Finder.
    func showMainWindow() {
        if let window = mainWindows.first {
            setDockIcon(visible: true)
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else if let openWindowAction {
            openWindowAction()
        } else {
            openPending = true   // menu bar label not set up yet (right after launch)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Closes a window that macOS restored at launch.
    func closeMainWindowAtLaunch() {
        mainWindows.forEach { $0.close() }
        scheduleUpdate()
    }

    /// After the notification: `willClose` arrives while the window is still visible.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateScheduled = false
            setDockIcon(visible: mainWindows.contains { $0.isVisible || $0.isMiniaturized })
        }
    }

    private func setDockIcon(visible: Bool) {
        let policy: NSApplication.ActivationPolicy = visible ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
        // Coming from .accessory the app must be (re)activated, otherwise its menu bar
        // stays hidden and the window may end up behind other apps.
        if visible { NSApp.activate(ignoringOtherApps: true) }
    }
}
