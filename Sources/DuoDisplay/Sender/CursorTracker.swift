import AppKit
import CoreGraphics
import os

/// Sender side: reports where the pointer is on the virtual display and what it looks like,
/// so the receiver can draw it locally instead of waiting for the video (capture + encode).
final class CursorTracker {
    /// Tap thread: binary cursorPosition payload, only when it changed.
    var onPosition: ((Data) -> Void)?
    /// Main thread: new cursor shape.
    var onImage: ((ControlMessage) -> Void)?

    private var tapThread: EventTapThread?
    private var imageTimer: Timer?
    private var boundsTimer: Timer?
    private var lastImageHash = 0
    private var displayID: CGDirectDisplayID = 0
    private let bounds = OSAllocatedUnfairLock(initialState: CGRect.null)
    private var lastSent = (x: Float(-1), y: Float(-1), visible: false)

    /// Returns false if the pointer cannot be observed (then the video must contain the cursor).
    func start(display: CGDirectDisplayID) -> Bool {
        displayID = display
        bounds.withLock { $0 = CGDisplayBounds(display) }
        lastImageHash = 0
        lastSent = (-1, -1, false)

        if tapThread == nil {
            let thread = EventTapThread { [weak self] _, _, event in
                self?.report(event.location)
                return Unmanaged.passUnretained(event)
            }
            guard thread.install(location: .cgSessionEventTap, options: .listenOnly,
                                 types: EventTypes.pointerMotion, enabled: true) else { return false }
            tapThread = thread
        } else {
            tapThread?.setEnabled(true)
        }
        imageTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.pollImage() }
        boundsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let b = CGDisplayBounds(self.displayID)
            self.bounds.withLock { $0 = b }   // user may rearrange displays
        }
        pollImage()
        if let location = CGEvent(source: nil)?.location { report(location) }
        return true
    }

    func stop() {
        tapThread?.setEnabled(false)
        imageTimer?.invalidate()
        boundsTimer?.invalidate()
        imageTimer = nil
        boundsTimer = nil
    }

    /// Sends the current position again (e.g. right after warping the pointer).
    func reportCurrentPosition() {
        if let location = CGEvent(source: nil)?.location { report(location, force: true) }
    }

    private func report(_ location: CGPoint, force: Bool = false) {
        let b = bounds.withLock { $0 }
        guard !b.isNull else { return }
        let visible = b.contains(location)
        let x = Float(location.x - b.minX), y = Float(location.y - b.minY)
        if !force && visible == lastSent.visible && (!visible || (x == lastSent.x && y == lastSent.y)) { return }
        lastSent = (x, y, visible)
        var payload = Data(capacity: 9)
        payload.appendLE(x.bitPattern)
        payload.appendLE(y.bitPattern)
        payload.append(visible ? 1 : 0)
        onPosition?(payload)
    }

    private func pollImage() {
        let cursor = NSCursor.currentSystem ?? NSCursor.arrow
        let image = cursor.image
        let hotSpot = cursor.hotSpot
        let size = image.size
        guard size.width > 0, size.height > 0, let tiff = image.tiffRepresentation else { return }
        var hasher = Hasher()
        hasher.combine(tiff)
        hasher.combine(hotSpot.x)
        hasher.combine(hotSpot.y)
        let hash = hasher.finalize()
        guard hash != lastImageHash else { return }
        lastImageHash = hash

        // Render at 2× so the pointer stays sharp on a Retina receiver.
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2),
                                         pixelsHigh: Int(size.height * 2), bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { return }

        var message = ControlMessage(.cursorImage)
        message.png = png
        message.cursorWidth = size.width
        message.cursorHeight = size.height
        message.hotspotX = hotSpot.x
        message.hotspotY = hotSpot.y
        onImage?(message)
    }
}
