import Foundation
import CoreGraphics
import os

/// Receiver side, "Normal Use" mode: watches (listen-only, never delays input) for the pointer
/// being pushed against the screen edge that faces the MacBook.
final class EdgeWatcher {
    /// Called on the tap thread with the relative height (0 = top … 1 = bottom) where the pointer left.
    var onCross: ((Double) -> Void)?
    /// Called on the tap thread when the pointer (no button held) moved into the picture-in-picture
    /// window's picture, with the spot (0…1 from its top-left) and the window it was in.
    var onPiPEnter: ((CGPoint, PiPTarget) -> Void)?

    private var tapThread: EventTapThread?
    private let edgeBox = OSAllocatedUnfairLock<ScreenEdge?>(initialState: nil)
    /// The picture-in-picture window to watch, and whether the pointer was seen outside it since
    /// watching (re)started: it has to come in from outside – not already sit there when the window
    /// opens or after ⌃⌥⌘D took the input back.
    private let pipBox = OSAllocatedUnfairLock(initialState: (target: PiPTarget?.none, armed: false))
    /// Tap thread: last time a covering window was looked up (rate limit while it stays covered).
    private var lastCoverCheckNs: UInt64 = 0
    // Tap thread only:
    private var push = 0.0
    private var displays: [CGRect] = []
    private var displaysRefreshedNs: UInt64 = 0

    var isInstalled: Bool { tapThread?.isInstalled ?? false }

    /// Needs the Accessibility permission.
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        let thread = EventTapThread { [weak self] _, type, event in
            switch type.rawValue {
            case EventTypes.mouseMoved: self?.handle(event, dragging: false)
            case EventTypes.leftDragged, EventTypes.rightDragged, EventTypes.otherDragged:
                self?.handle(event, dragging: true)
            case EventTypes.leftMouseDown, EventTypes.rightMouseDown, EventTypes.otherMouseDown:
                self?.disarmPiP(at: event.location)
            default: break
            }
            return Unmanaged.passUnretained(event)
        }
        // Session level: the pointer position in the event is final (already clamped to the screen).
        guard thread.install(location: .cgSessionEventTap, options: .listenOnly,
                             types: [EventTypes.mouseMoved, EventTypes.leftMouseDown, EventTypes.rightMouseDown,
                                     EventTypes.otherMouseDown, EventTypes.leftDragged, EventTypes.rightDragged,
                                     EventTypes.otherDragged],
                             enabled: false) else { return false }
        tapThread = thread
        return true
    }

    /// `nil` switches watching off (screen edge and / or picture-in-picture window).
    func watch(_ edge: ScreenEdge?, pip: PiPTarget? = nil) {
        edgeBox.withLock { $0 = edge }
        pipBox.withLock { box in
            if box.target != pip { box.armed = false }
            box.target = pip
        }
        tapThread?.setEnabled(edge != nil || pip != nil)
    }

    private func handle(_ event: CGEvent, dragging: Bool) {
        if handlePiP(event, dragging: dragging) { return }
        // With a button held (dragging a window, text …) the pointer stays on this Mac.
        guard !dragging, let edge = edgeBox.withLock({ $0 }) else {
            push = 0
            return
        }
        let now = hostTimeNs()
        if now &- displaysRefreshedNs > 1_000_000_000 || displays.isEmpty {
            displays = EdgeGeometry.activeDisplays()
            displaysRefreshedNs = now
        }
        let p = event.location
        let dx = event.getDoubleValueField(.mouseEventDeltaX)
        let towardsEdge = edge == .left ? dx < 0 : dx > 0
        guard let screen = EdgeGeometry.outerEdgeDisplay(at: p, edge: edge, displays: displays) else {
            push = 0
            return
        }
        if towardsEdge {
            push += abs(dx)
        } else if dx != 0 {
            push = 0
        }
        if push >= EdgeGeometry.pushThreshold {
            push = 0
            onCross?(EdgeGeometry.fraction(of: p.y, in: screen))
        }
    }

    /// Returns true when the pointer moved into the picture-in-picture window's picture.
    private func handlePiP(_ event: CGEvent, dragging: Bool) -> Bool {
        let p = event.location
        let (target, armed) = pipBox.withLock { ($0.target, $0.armed) }
        guard let target else { return false }
        let trigger = PiPGeometry.triggerRect(video: target.video)
        guard trigger.contains(p) else {
            // Outside the picture (title bar and resize border included): armed for the next entry.
            if !armed, !target.video.contains(p) {
                pipBox.withLock { if $0.target == target { $0.armed = true } }
            }
            return false
        }
        // Dragging something over the window (or resizing it) never jumps into the MacBook.
        guard armed, !dragging else { return false }
        let now = hostTimeNs()
        if now &- lastCoverCheckNs < 40_000_000 { return false }
        if Self.covered(p, above: target.windowID) {
            lastCoverCheckNs = now
            return false
        }
        lastCoverCheckNs = 0
        let entered = pipBox.withLock { box -> Bool in
            guard box.target == target, box.armed else { return false }
            box.armed = false
            return true
        }
        guard entered else { return false }
        onPiPEnter?(PiPGeometry.normalized(p, in: target.video), target)
        return true
    }

    /// A click inside the picture can only hit something lying over it (e.g. a menu item): when that
    /// closes, the pointer is left in the picture – which must not count as moving in. Tap thread.
    private func disarmPiP(at p: CGPoint) {
        pipBox.withLock { box in
            if let target = box.target, PiPGeometry.triggerRect(video: target.video).contains(p) { box.armed = false }
        }
    }

    /// A menu, popover or other floating window lies over the picture at `p`.
    private static func covered(_ p: CGPoint, above windowID: CGWindowID) -> Bool {
        !coveringWindows(p, above: windowID).isEmpty
    }

    /// Windows above `windowID` at `p` (owner, layer) – also for the self test's diagnostics.
    static func coveringWindows(_ p: CGPoint, above windowID: CGWindowID) -> [String] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID)
                as? [[String: Any]] else { return [] }
        // The Dock (and similar overlays) keep an invisible window over the whole screen – not a cover.
        let screens = EdgeGeometry.activeDisplays()
        var result: [String] = []
        for info in list {
            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(p),
                  !screens.contains(where: { $0.insetBy(dx: -1, dy: -1).contains(bounds) && bounds.width >= $0.width - 1
                                             && bounds.height >= $0.height - 1 }) else { continue }
            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1
            let layer = (info[kCGWindowLayer as String] as? Int) ?? 0
            if alpha > 0.01 {
                result.append("\(info[kCGWindowOwnerName as String] as? String ?? "?") (layer \(layer), \(Int(bounds.width))×\(Int(bounds.height)))")
            }
        }
        return result
    }
}
