import Foundation
import CoreGraphics

/// "Normal Use" mode: move the iMac pointer over its edge onto the MacBook (and back),
/// like Universal Control – but over the existing DuoDisplay connection.
///
///   iMac (receiver)                                  MacBook (sender)
///   EdgeWatcher (listen-only tap) sees the pointer
///   pushing against the edge facing the MacBook ──► edgeEnter(fraction) → pointer appears at
///   InputCapture swallows + forwards all input ───►   the facing edge, input is injected
///   pointer reappears at the edge ◄──────────────── edgeLeave(fraction) when the injected pointer
///                                                    pushes against that edge again
/// ⌃⌥⌘D on the iMac, a dropped connection or a silent MacBook (no pong for 1.5 s) always hand
/// keyboard and pointer back to the iMac.
enum ScreenEdge: String, Codable {
    case left, right

    var opposite: ScreenEdge { self == .left ? .right : .left }
}

enum EdgeGeometry {
    /// How far (pt of raw pointer motion) the pointer has to be pushed against the edge before it
    /// switches Macs. Small resistance so aiming at something at the screen edge doesn't jump over.
    static let pushThreshold = 6.0

    /// All active displays in global CG coordinates (origin top-left of the main display).
    static func activeDisplays() -> [CGRect] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { CGDisplayBounds($0) }
    }

    /// The display under `p` if `p` sits on its `edge` and no other display continues beyond it there.
    static func outerEdgeDisplay(at p: CGPoint, edge: ScreenEdge, displays: [CGRect]) -> CGRect? {
        guard let screen = displays.first(where: { $0.insetBy(dx: -1, dy: -1).contains(p) }) else { return nil }
        let onEdge = edge == .left ? p.x <= screen.minX + 0.5 : p.x >= screen.maxX - 1.5
        guard onEdge else { return nil }
        let beyond = CGPoint(x: edge == .left ? screen.minX - 2 : screen.maxX + 2, y: p.y)
        return displays.contains(where: { $0.contains(beyond) }) ? nil : screen
    }

    /// The display whose `edge` is the outermost one (where the other Mac "sits").
    static func outermostDisplay(_ edge: ScreenEdge, displays: [CGRect]) -> CGRect? {
        edge == .left ? displays.min { $0.minX < $1.minX } : displays.max { $0.maxX < $1.maxX }
    }

    /// `entry` moved by the pointer motion that happened while switching back, kept on a screen
    /// (falls back to the entry display, never past the outer edge).
    static func landingPoint(entry: CGPoint, carry: CGVector, displays: [CGRect]) -> CGPoint {
        let p = CGPoint(x: entry.x + carry.dx, y: entry.y + carry.dy)
        if displays.contains(where: { $0.contains(p) }) { return p }
        guard let screen = displays.first(where: { $0.contains(entry) }) else { return entry }
        return CGPoint(x: min(max(p.x, screen.minX + 1), screen.maxX - 2),
                       y: min(max(p.y, screen.minY), screen.maxY - 1))
    }

    /// Position along a display's vertical edge, 0 = top, 1 = bottom.
    static func fraction(of y: CGFloat, in screen: CGRect) -> Double {
        guard screen.height > 0 else { return 0.5 }
        return min(max(Double((y - screen.minY) / screen.height), 0), 1)
    }

    /// Where the pointer enters a Mac: just inside `edge` of the outermost display there,
    /// at the same relative height it left the other Mac.
    static func entryPoint(edge: ScreenEdge, fraction: Double, displays: [CGRect]) -> CGPoint? {
        guard let screen = outermostDisplay(edge, displays: displays) else { return nil }
        let y = screen.minY + CGFloat(min(max(fraction, 0), 1)) * (screen.height - 1)
        return CGPoint(x: edge == .left ? screen.minX + 2 : screen.maxX - 3, y: y)
    }
}

/// Side of the picture-in-picture window (= of the MacBook's main screen) the pointer left through.
enum PiPSide: String, Codable {
    case left, right, top, bottom
}

/// Picture-in-picture ("Normal Use", ⌃⌥⌘P): the MacBook's main screen in a window on the iMac.
/// Moving the iMac pointer into the picture (any side) hands keyboard and pointer to the MacBook;
/// pushing the MacBook pointer out over any side of its main screen hands them back, and the iMac
/// pointer reappears just outside the window at the matching spot.
/// All rects in global CG coordinates (origin top-left of the main display), in points.
enum PiPGeometry {
    /// Inset of the area that takes the pointer over: keeps the window's resize zone at its sides
    /// and bottom usable without jumping into the MacBook.
    static let triggerInset: CGFloat = 4
    /// How far outside the window the pointer lands when it comes back.
    static let landingMargin: CGFloat = 3

    static func triggerRect(video: CGRect) -> CGRect {
        let r = video.insetBy(dx: triggerInset, dy: 0)
        return CGRect(x: r.minX, y: r.minY, width: r.width, height: max(0, r.height - triggerInset))
    }

    /// Position in the picture, 0…1 from its top-left corner.
    static func normalized(_ p: CGPoint, in video: CGRect) -> CGPoint {
        guard video.width > 0, video.height > 0 else { return CGPoint(x: 0.5, y: 0.5) }
        return CGPoint(x: min(max((p.x - video.minX) / video.width, 0), 1),
                       y: min(max((p.y - video.minY) / video.height, 0), 1))
    }

    /// MacBook points per iMac point, so the pointer in the picture moves as fast as the hand.
    static func motionScale(macPoints: CGSize, video: CGRect) -> Double {
        guard video.width > 0, macPoints.width > 0 else { return 1 }
        return min(max(Double(macPoints.width / video.width), 0.25), 16)
    }

    /// Where the MacBook pointer starts: same relative spot on its main screen.
    static func entryPoint(_ n: CGPoint, screen: CGRect) -> CGPoint {
        CGPoint(x: screen.minX + min(max(n.x, 0), 1) * (screen.width - 1),
                y: screen.minY + min(max(n.y, 0), 1) * (screen.height - 1))
    }

    /// The side a wanted pointer position overshoots `screen` the most, and by how much (nil = inside).
    static func overshoot(_ p: CGPoint, screen: CGRect) -> (side: PiPSide, by: Double)? {
        let candidates: [(PiPSide, CGFloat)] = [(.left, screen.minX - p.x), (.right, p.x - (screen.maxX - 1)),
                                               (.top, screen.minY - p.y), (.bottom, p.y - (screen.maxY - 1))]
        guard let best = candidates.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        return (best.0, Double(best.1))
    }

    /// Keeps the MacBook pointer on its main screen while the picture is controlled.
    static func clamp(_ p: CGPoint, to screen: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, screen.minX), screen.maxX - 1), y: min(max(p.y, screen.minY), screen.maxY - 1))
    }

    /// Where the iMac pointer comes back: just outside `window` (whole frame incl. title bar) on
    /// `side`, at the spot `n` of the picture, moved on by `carry` (motion that was still underway)
    /// unless that would put it back into the window. Kept on a screen.
    static func landingPoint(side: PiPSide, n: CGPoint, video: CGRect, window: CGRect,
                             carry: CGVector, displays: [CGRect]) -> CGPoint {
        var p = CGPoint(x: video.minX + min(max(n.x, 0), 1) * video.width,
                        y: video.minY + min(max(n.y, 0), 1) * video.height)
        switch side {
        case .left: p.x = window.minX - landingMargin
        case .right: p.x = window.maxX + landingMargin
        case .top: p.y = window.minY - landingMargin
        case .bottom: p.y = window.maxY + landingMargin
        }
        let moved = CGPoint(x: p.x + carry.dx, y: p.y + carry.dy)
        if !window.contains(moved) { p = moved }
        if displays.contains(where: { $0.contains(p) }) { return p }
        // Off every screen (window at the screen edge): onto the nearest screen.
        guard let screen = displays.min(by: { distance(p, $0) < distance(p, $1) }) else { return p }
        return CGPoint(x: min(max(p.x, screen.minX), screen.maxX - 1), y: min(max(p.y, screen.minY), screen.maxY - 1))
    }

    private static func distance(_ p: CGPoint, _ r: CGRect) -> CGFloat {
        let dx = max(r.minX - p.x, 0, p.x - r.maxX), dy = max(r.minY - p.y, 0, p.y - r.maxY)
        return dx * dx + dy * dy
    }

    /// Converts an AppKit screen rect (origin bottom-left of the primary screen) to CG coordinates.
    static func cgRect(fromCocoa r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }
}

/// Moves the pointer without macOS freezing the real mouse / trackpad afterwards.
/// CGWarpMouseCursorPosition alone suppresses local hardware events for 0.25 s – exactly the
/// "pointer sticks at the edge for a moment" when it comes back. A combined-session event source
/// with a zero suppression interval lifts that (same approach as Synergy/Deskflow); the posted
/// mouse-moved event also updates hover state under the new position right away.
enum PointerWarp {
    private static let source: CGEventSource? = {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// Any thread.
    static func move(to point: CGPoint) {
        guard let source else {
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(1)
            return
        }
        CGWarpMouseCursorPosition(point)
        CGAssociateMouseAndMouseCursorPosition(1)
        CGEvent(mouseEventSource: source, mouseType: .mouseMoved, mouseCursorPosition: point,
                mouseButton: .left)?.post(tap: .cgSessionEventTap)
    }
}

/// Hides the pointer while DuoDisplay is NOT the active app (needed while the iMac keyboard and
/// trackpad control the MacBook in "Normal Use" mode). NSCursor.hide only works for the
/// frontmost app; the WindowServer property below lifts that (same approach as Synergy/Deskflow).
/// Falls back to a visible, frozen pointer if the private call ever disappears.
enum BackgroundCursor {
    private static var prepared = false
    private static var hidden = false

    private static func prepare() {
        guard !prepared else { return }
        prepared = true
        typealias DefaultConnection = @convention(c) () -> Int32
        typealias SetProperty = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let connSym = dlsym(rtldDefault, "_CGSDefaultConnection"),
              let setSym = dlsym(rtldDefault, "CGSSetConnectionProperty") else {
            ddLog.notice("Hiding the pointer in the background is unavailable")
            return
        }
        let connection = unsafeBitCast(connSym, to: DefaultConnection.self)()
        _ = unsafeBitCast(setSym, to: SetProperty.self)(connection, connection,
                                                        "SetsCursorInBackground" as CFString, kCFBooleanTrue)
    }

    /// Main thread.
    static func hide() {
        guard !hidden else { return }
        prepare()
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    /// Main thread.
    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
}

/// `DuoDisplay --edgetest`: geometry of the edge switch with made-up display arrangements.
enum EdgeSelfTest {
    static func run() -> Bool {
        var ok = true
        func check(_ name: String, _ condition: Bool) {
            print((condition ? "✓ " : "✗ ") + name)
            ok = ok && condition
        }
        let imac = CGRect(x: 0, y: 0, width: 2240, height: 1260)
        let extraRight = CGRect(x: 2240, y: 0, width: 1920, height: 1080)
        let extraLeftLow = CGRect(x: -1920, y: 600, width: 1920, height: 1080)

        check("iMac alone: left edge detected",
              EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 0, y: 630), edge: .left, displays: [imac]) == imac)
        check("iMac alone: not 3 pt before the edge",
              EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 3, y: 630), edge: .left, displays: [imac]) == nil)
        check("right edge with a neighboring display doesn’t count",
              EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 2239, y: 500), edge: .right, displays: [imac, extraRight]) == nil)
        check("right edge of the outer display counts",
              EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 4159, y: 500), edge: .right, displays: [imac, extraRight]) == extraRight)
        check("left edge above an offset neighbor counts",
              EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 0, y: 100), edge: .left, displays: [imac, extraLeftLow]) == imac)
        check("left edge next to the neighbor doesn’t count",
              EdgeGeometry.outerEdgeDisplay(at: CGPoint(x: 0, y: 900), edge: .left, displays: [imac, extraLeftLow]) == nil)

        let f = EdgeGeometry.fraction(of: 945, in: imac)
        check("height 945 of 1260 = 0.75", abs(f - 0.75) < 0.001)
        let macbook = CGRect(x: 0, y: 0, width: 1512, height: 982)
        if let p = EdgeGeometry.entryPoint(edge: .right, fraction: 0.75, displays: [macbook]) {
            check("entry on MacBook right inside, same relative height",
                  macbook.contains(p) && p.x > macbook.maxX - 4 && abs(Double(p.y) - 0.75 * 981) < 1)
        } else { check("entry point MacBook", false) }
        if let p = EdgeGeometry.entryPoint(edge: .left, fraction: 0, displays: [imac, extraLeftLow]) {
            check("entry on the left uses the outermost display", extraLeftLow.contains(p))
        } else { check("entry point left", false) }
        check("ScreenEdge.opposite", ScreenEdge.left.opposite == .right)

        let back = CGPoint(x: 2237, y: 600)
        check("return: overshoot carried over",
              EdgeGeometry.landingPoint(entry: back, carry: CGVector(dx: -40, dy: 10), displays: [imac])
                == CGPoint(x: 2197, y: 610))
        let past = EdgeGeometry.landingPoint(entry: back, carry: CGVector(dx: 50, dy: 0), displays: [imac])
        check("return: never past the outer edge", imac.contains(past) && past.x < imac.maxX - 1)
        check("return: overshoot onto neighboring display allowed",
              EdgeGeometry.landingPoint(entry: CGPoint(x: 2, y: 100), carry: CGVector(dx: -30, dy: 0),
                                        displays: [imac, CGRect(x: -1920, y: 0, width: 1920, height: 1080)]).x == -28)

        // Picture-in-picture
        let mbMain = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let video = CGRect(x: 1000, y: 300, width: 735, height: 478)       // half size
        let pipWindow = CGRect(x: 1000, y: 272, width: 735, height: 506)   // + 28 pt title bar
        check("PiP: motion ×2 at half size",
              abs(PiPGeometry.motionScale(macPoints: mbMain.size, video: video) - 2) < 0.001)
        let trig = PiPGeometry.triggerRect(video: video)
        check("PiP: trigger area leaves the resize border free",
              !trig.contains(CGPoint(x: 1001, y: 500)) && trig.contains(CGPoint(x: 1010, y: 301))
                && !trig.contains(CGPoint(x: 1300, y: 777)))
        let nLeft = PiPGeometry.normalized(CGPoint(x: 1004, y: 539), in: video)
        let eLeft = PiPGeometry.entryPoint(nLeft, screen: mbMain)
        check("PiP: in from the left → MacBook pointer left, same height",
              eLeft.x < 10 && abs(eLeft.y - 0.5 * 955) < 2)
        let eBottom = PiPGeometry.entryPoint(PiPGeometry.normalized(CGPoint(x: 1367, y: 774), in: video), screen: mbMain)
        check("PiP: in from below → MacBook pointer at the bottom", eBottom.y > 940 && abs(eBottom.x - 0.5 * 1469) < 2)
        let eTopRight = PiPGeometry.entryPoint(CGPoint(x: 1, y: 0), screen: mbMain)
        check("PiP: top right corner stays on screen", mbMain.contains(eTopRight))
        check("PiP: no exit from inside", PiPGeometry.overshoot(CGPoint(x: 700, y: 400), screen: mbMain) == nil)
        check("PiP: out to the right", PiPGeometry.overshoot(CGPoint(x: 1475, y: 400), screen: mbMain)?.side == .right)
        check("PiP: out at the top", PiPGeometry.overshoot(CGPoint(x: 700, y: -3), screen: mbMain)?.side == .top)
        check("PiP: corner, the stronger side wins",
              PiPGeometry.overshoot(CGPoint(x: -2, y: 962), screen: mbMain)?.side == .bottom)
        check("PiP: pointer stays on the MacBook screen",
              PiPGeometry.clamp(CGPoint(x: 2000, y: -5), to: mbMain) == CGPoint(x: 1469, y: 0))
        let landR = PiPGeometry.landingPoint(side: .right, n: CGPoint(x: 1, y: 0.25), video: video, window: pipWindow,
                                             carry: CGVector(dx: 12, dy: 4), displays: [imac])
        check("PiP: out to the right → right of the window, overshoot carried over",
              abs(landR.x - (1735 + 3 + 12)) < 0.01 && abs(landR.y - (300 + 0.25 * 478 + 4)) < 0.01)
        let landT = PiPGeometry.landingPoint(side: .top, n: CGPoint(x: 0.5, y: 0), video: video, window: pipWindow,
                                             carry: .zero, displays: [imac])
        check("PiP: out at the top → above the title bar", landT.y < pipWindow.minY && abs(landT.x - 1367.5) < 0.01)
        let landBack = PiPGeometry.landingPoint(side: .left, n: CGPoint(x: 0, y: 0.5), video: video, window: pipWindow,
                                                carry: CGVector(dx: 30, dy: 0), displays: [imac])
        check("PiP: overshoot back into the window is discarded", !pipWindow.contains(landBack) && landBack.x < 1000)
        let edgeWindow = CGRect(x: 1700, y: 0, width: 540, height: 380)
        let landOff = PiPGeometry.landingPoint(side: .right, n: CGPoint(x: 1, y: 0.5),
                                               video: CGRect(x: 1700, y: 28, width: 540, height: 352),
                                               window: edgeWindow, carry: .zero, displays: [imac])
        check("PiP: window at screen edge → pointer stays on screen", imac.contains(landOff))
        check("PiP: Cocoa → CG",
              PiPGeometry.cgRect(fromCocoa: CGRect(x: 10, y: 1000, width: 100, height: 60), primaryHeight: 1260)
                == CGRect(x: 10, y: 200, width: 100, height: 60))

        print(ok ? "\nRESULT: OK" : "\nRESULT: FAILED")
        return ok
    }
}
