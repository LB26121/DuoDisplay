import AppKit
import QuartzCore

/// Borderless, opaque window covering the whole screen (above menu bar and Dock, on every Space).
/// Shows/hides instantly – no full-screen animation, no Space switch. Its only content is the
/// Metal layer (video) with the pointer as a small sublayer on top.
final class StreamWindowController {
    private final class KeyableWindow: NSWindow {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    let window: NSWindow
    private let presenter: MetalPresenter

    var isVisible: Bool { window.isVisible }

    init(presenter: MetalPresenter) {
        self.presenter = presenter
        window = KeyableWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 500),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none

        // Layer-hosting (nothing else is composited on top); the video layer is attached in show(),
        // it may be in the picture-in-picture window until then.
        let view = NSView()
        view.wantsLayer = true
        window.contentView = view
    }

    /// Main thread.
    func show(on screen: NSScreen, contentPoints: CGSize, topInset: CGFloat, localCursor: Bool) {
        // The video layer may still sit in the picture-in-picture window.
        if window.contentView?.layer !== presenter.layer {
            window.contentView?.layer = presenter.layer
            window.contentView?.wantsLayer = true
        }
        window.setFrame(screen.frame, display: false)
        if let view = window.contentView {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            presenter.layer.frame = view.bounds
            CATransaction.commit()
        }
        let scale = screen.backingScaleFactor
        presenter.configure(sizePixels: CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale),
                            scale: scale, contentPoints: contentPoints, topInsetPoints: topInset,
                            localCursor: localCursor)
        window.orderFrontRegardless()
        window.makeKey()
    }

    /// Main thread.
    func hide() {
        window.orderOut(nil)
        presenter.clear()
        // Free the video layer for the picture-in-picture window.
        if window.contentView?.layer === presenter.layer { window.contentView?.layer = CALayer() }
    }

    /// Main thread.
    func setCursorImage(_ image: CGImage, sizePoints: CGSize, hotspot: CGPoint) {
        presenter.setCursorImage(image, sizePoints: sizePoints, hotspot: hotspot)
    }

    /// Any thread. (x, y) in points of the streamed display, top-left origin.
    func updateCursor(x: CGFloat, y: CGFloat, visible: Bool) {
        presenter.updateCursor(x: x, y: y, visible: visible)
    }
}
