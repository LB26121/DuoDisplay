import Foundation

/// Keeps macOS from putting this menu-bar app into App Nap while the two Macs are connected.
/// Without it a windowless accessory app gets throttled (lower CPU/IO priority, coalesced timers),
/// which delays forwarded input in "Normal nutzen" – there the iMac drives the MacBook over the
/// screen edge while neither app shows a window. Does not keep the Mac awake.
final class LatencyActivity {
    private let reason: String
    private var token: NSObjectProtocol?

    init(reason: String) { self.reason = reason }

    deinit { set(false) }

    /// Main thread.
    func set(_ active: Bool) {
        if active, token == nil {
            token = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical], reason: reason)
        } else if !active, let token {
            ProcessInfo.processInfo.endActivity(token)
            self.token = nil
        }
    }
}
