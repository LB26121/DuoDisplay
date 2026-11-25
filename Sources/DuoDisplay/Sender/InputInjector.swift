import Foundation
import CoreGraphics

/// Sender side: replays the receiver's raw input events on this Mac.
/// Events are recreated byte-for-byte (keeps scroll phases, momentum, gesture data, click counts);
/// only the pointer position is recomputed here from the relative motion.
/// Not thread-safe: call from one serial queue.
final class InputInjector {
    private var lastPosted: CGPoint?
    private var lastPostNs: UInt64 = 0
    private var pressedKeys = Set<Int64>()
    private var pressedButtons = Set<Int64>()
    private var displays: [CGRect] = []
    private var displaysRefreshedNs: UInt64 = 0
    private let source = CGEventSource(stateID: .hidSystemState)
    /// "Normal nutzen": the edge where the pointer goes back to the receiver (nil = display mode).
    private var exitEdge: ScreenEdge?
    private var exitPush = 0.0
    /// Called (on the injector's queue) when the pointer is pushed out over `exitEdge`,
    /// with the relative height 0…1 and the receiver's timestamp of the event that pushed it out.
    /// The session then stops passing input here.
    /// The third value is a diagnostics line for the receiver's log.
    var onEdgeExit: ((Double, UInt64, String) -> Void)?
    /// Picture-in-picture session: the pointer is kept on the screen shown in the picture (`display`:
    /// the main screen, or the extra virtual one) and leaves over any of its sides; motion is
    /// multiplied by `scale` (MacBook points per iMac point).
    private struct PiPSession { var display: CGDirectDisplayID; var screen: CGRect; var scale: Double }
    private var pip: PiPSession?
    /// Called (on the injector's queue) when the pointer is pushed out of the main screen during a
    /// picture-in-picture session: position 0…1 on it, side, receiver timestamp of that event.
    var onPiPExit: ((CGPoint, PiPSide, UInt64) -> Void)?
    // Diagnostics: how long the pointer sat at the exit edge before it left.
    private var atEdgeSinceNs: UInt64?
    private var atEdgeEvents = 0
    private var atEdgeResets = 0
    private var atEdgeMaxPush = 0.0

    /// The receiver's pointer crossed over: show the pointer at `edge` at the same relative height.
    func beginEdgeSession(edge: ScreenEdge, fraction: Double) {
        pip = nil
        exitEdge = edge
        exitPush = 0
        refreshDisplays(hostTimeNs())
        guard let entry = EdgeGeometry.entryPoint(edge: edge, fraction: fraction, displays: displays) else { return }
        CGWarpMouseCursorPosition(entry)
        CGAssociateMouseAndMouseCursorPosition(1)
        lastPosted = entry
        lastPostNs = hostTimeNs()
    }

    func endEdgeSession() {
        exitEdge = nil
        pip = nil
        exitPush = 0
    }

    /// The receiver's pointer moved into the picture-in-picture window at `n` (0…1 of the picture):
    /// show the pointer at the same spot of `display` (the screen shown in the picture).
    func beginPiPSession(n: CGPoint, scale: Double, display: CGDirectDisplayID) {
        exitEdge = nil
        exitPush = 0
        refreshDisplays(hostTimeNs())
        let screen = CGDisplayBounds(display)
        pip = PiPSession(display: display, screen: screen, scale: min(max(scale, 0.25), 16))
        let entry = PiPGeometry.entryPoint(n, screen: screen)
        CGWarpMouseCursorPosition(entry)
        CGAssociateMouseAndMouseCursorPosition(1)
        lastPosted = entry
        lastPostNs = hostTimeNs()
    }

    func handle(_ data: Data) {
        guard let event = CGEvent(withDataAllocator: kCFAllocatorDefault, data: data as CFData) else { return }
        let receiverTime = event.timestamp   // overwritten below before posting
        let now = hostTimeNs()
        if now &- displaysRefreshedNs > 500_000_000 { refreshDisplays(now) }

        // The system cursor position lags slightly behind events we just posted.
        let system = CGEvent(source: nil)?.location ?? .zero
        let base = (lastPosted != nil && now &- lastPostNs < 100_000_000) ? lastPosted! : system

        let type = event.type.rawValue
        if let session = pip, [5, 6, 7, 27].contains(type) {
            guard movePiP(event, type: type, session: session, base: base, now: now, receiverTime: receiverTime) else { return }
            event.timestamp = CGEventTimestamp(now)
            event.post(tap: .cghidEventTap)
            return
        }
        switch type {
        case 5, 6, 7, 27:   // moved / dragged
            let dx = event.getDoubleValueField(.mouseEventDeltaX)
            let dy = event.getDoubleValueField(.mouseEventDeltaY)
            let wanted = CGPoint(x: base.x + dx, y: base.y + dy)
            // Only without a button held: a drag stays on this Mac (the press would get lost), and
            // push built up before the button went down does not count afterwards.
            if type != 5 { exitPush = 0 }
            if type == 5, let edge = exitEdge, let fraction = edgeExit(wanted, base: base, dx: dx, edge: edge) {
                exitEdge = nil
                let ms = atEdgeSinceNs.map { Double(now &- $0) / 1e6 } ?? -1
                let info = String(format: "MacBook: %.0f ms am Rand, %d Ereignisse, %d× zurückgesetzt, max. Druck %.1f pt, %d Bildschirm(e), dx %.1f",
                                  ms, atEdgeEvents, atEdgeResets, atEdgeMaxPush, displays.count, dx)
                atEdgeSinceNs = nil
                onEdgeExit?(fraction, receiverTime, info)
                return
            }
            let target = clamp(wanted, from: base)
            if let edge = exitEdge, let home = displays.first(where: { $0.contains(target) }) {
                let edgeX = edge == .left ? home.minX : home.maxX - 1
                if abs(target.x - edgeX) < 1 {
                    if atEdgeSinceNs == nil { atEdgeSinceNs = now; atEdgeEvents = 0; atEdgeResets = 0; atEdgeMaxPush = 0 }
                    atEdgeEvents += 1
                } else {
                    atEdgeSinceNs = nil
                }
            }
            event.location = target
            event.setDoubleValueField(.mouseEventDeltaX, value: target.x - base.x)
            event.setDoubleValueField(.mouseEventDeltaY, value: target.y - base.y)
            lastPosted = target
            lastPostNs = now
        case 1, 3, 25:      // button down
            pressedButtons.insert(event.getIntegerValueField(.mouseEventButtonNumber))
            event.location = base
            lastPosted = base
            lastPostNs = now
        case 2, 4, 26:      // button up
            pressedButtons.remove(event.getIntegerValueField(.mouseEventButtonNumber))
            event.location = base
        case 10:
            pressedKeys.insert(event.getIntegerValueField(.keyboardEventKeycode))
        case 11:
            pressedKeys.remove(event.getIntegerValueField(.keyboardEventKeycode))
        default:            // scroll, gestures, force touch …: deliver at the pointer
            event.location = base
        }
        event.timestamp = CGEventTimestamp(now)
        event.post(tap: .cghidEventTap)
    }

    /// Pointer motion during a picture-in-picture session: scaled, kept on the main screen; pushed
    /// out over any side (no button held) it goes back to the receiver – returns false then.
    private func movePiP(_ event: CGEvent, type: UInt32, session: PiPSession, base: CGPoint,
                         now: UInt64, receiverTime: UInt64) -> Bool {
        let dx = event.getDoubleValueField(.mouseEventDeltaX) * session.scale
        let dy = event.getDoubleValueField(.mouseEventDeltaY) * session.scale
        let wanted = CGPoint(x: base.x + dx, y: base.y + dy)
        if type != EventTypes.mouseMoved { exitPush = 0 }   // a drag starts the push from scratch
        if let over = PiPGeometry.overshoot(wanted, screen: session.screen) {
            // Only without a button held: a drag stays inside (the press would get lost).
            if type == EventTypes.mouseMoved {
                exitPush += over.by
                if exitPush >= EdgeGeometry.pushThreshold * session.scale {
                    exitPush = 0
                    pip = nil
                    let at = PiPGeometry.clamp(wanted, to: session.screen)
                    onPiPExit?(PiPGeometry.normalized(at, in: session.screen), over.side, receiverTime)
                    return false
                }
            }
        } else if dx != 0 || dy != 0 {
            exitPush = 0
        }
        let target = PiPGeometry.clamp(wanted, to: session.screen)
        event.location = target
        event.setDoubleValueField(.mouseEventDeltaX, value: target.x - base.x)
        event.setDoubleValueField(.mouseEventDeltaY, value: target.y - base.y)
        lastPosted = target
        lastPostNs = now
        return true
    }

    /// Puts the pointer in the middle of the given display (used when switching to display mode).
    func warp(toCenterOf display: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(display)
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        CGWarpMouseCursorPosition(center)
        CGAssociateMouseAndMouseCursorPosition(1)
        lastPosted = center
        lastPostNs = hostTimeNs()
    }

    /// Releases everything the receiver still holds down (prevents stuck ⌘/⌥/⌃ or buttons
    /// when the mode switches mid-press or the connection drops).
    func releaseAll() {
        for key in pressedKeys {
            CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(key), keyDown: false)?.post(tap: .cghidEventTap)
        }
        pressedKeys.removeAll()
        if let flags = CGEvent(source: source) {
            flags.type = .flagsChanged
            flags.flags = []
            flags.post(tap: .cghidEventTap)
        }
        let location = CGEvent(source: nil)?.location ?? .zero
        for button in pressedButtons {
            let type: CGEventType = button == 0 ? .leftMouseUp : (button == 1 ? .rightMouseUp : .otherMouseUp)
            CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: location,
                    mouseButton: CGMouseButton(rawValue: UInt32(button)) ?? .center)?.post(tap: .cghidEventTap)
        }
        pressedButtons.removeAll()
        lastPosted = nil
    }

    /// Pointer pushed against the outer `edge` (no display beyond) by more than the threshold?
    /// Returns the relative height where it left.
    private func edgeExit(_ p: CGPoint, base: CGPoint, dx: Double, edge: ScreenEdge) -> Double? {
        let towards = edge == .left ? dx < 0 : dx > 0
        // Measured from where clamp() parks the pointer (minX / maxX − 1), so sub-point trackpad
        // deltas count on both edges alike.
        guard towards,
              let home = displays.first(where: { $0.contains(base) }) ?? displays.first,
              p.y >= home.minY, p.y < home.maxY,
              edge == .left ? p.x < home.minX : p.x > home.maxX - 1,
              !displays.contains(where: { $0.contains(CGPoint(x: edge == .left ? home.minX - 1 : home.maxX, y: p.y)) })
        else {
            if dx != 0 {
                if exitPush > 0 { atEdgeResets += 1 }
                exitPush = 0
            }
            return nil
        }
        exitPush += edge == .left ? home.minX - p.x : p.x - (home.maxX - 1)
        atEdgeMaxPush = max(atEdgeMaxPush, exitPush)
        guard exitPush >= EdgeGeometry.pushThreshold else { return nil }
        exitPush = 0
        return EdgeGeometry.fraction(of: p.y, in: home)
    }

    private func refreshDisplays(_ now: UInt64) {
        displaysRefreshedNs = now
        displays = EdgeGeometry.activeDisplays()
        if let display = pip?.display { pip?.screen = CGDisplayBounds(display) }
    }

    /// Keeps the pointer on a screen. Stays 1 pt inside outer edges so a forwarded motion never
    /// "pushes" against an edge (which could trigger Universal Control or hot corners).
    private func clamp(_ p: CGPoint, from base: CGPoint) -> CGPoint {
        if displays.contains(where: { $0.contains(p) }) { return p }
        let home = displays.first { $0.contains(base) } ?? displays.first ?? CGRect(x: 0, y: 0, width: 1, height: 1)
        return CGPoint(x: min(max(p.x, home.minX), home.maxX - 1),
                       y: min(max(p.y, home.minY), home.maxY - 1))
    }
}
