import AppKit
import QuartzCore

/// Where the picture-in-picture window is, in global CG coordinates (points, origin top-left of
/// the primary screen): the picture itself, the whole window incl. title bar, its window number.
struct PiPTarget: Equatable {
    var video: CGRect
    var window: CGRect
    var windowID: CGWindowID
}

/// "Normal Use", ⌃⌥⌘P: the MacBook's main screen (mirrored) or an extra screen of it (extended)
/// in a small floating window on this Mac. Title bar to move it and to switch between the two,
/// sides and corners to resize it (aspect ratio stays that of the MacBook), close button = ⌃⌥⌘P. Never takes focus away from the app in front (non-activating panel).
/// Moving the pointer into the picture itself hands keyboard and pointer to the MacBook
/// (EdgeWatcher + ReceiverService); the video and the MacBook pointer come from the same
/// MetalPresenter as the full-screen stream, which is never shown at the same time.
final class PiPWindowController: NSObject, NSWindowDelegate {
    /// Main thread: the user clicked the close button.
    var onClose: (() -> Void)?
    /// Main thread: moved, resized, other screen.
    var onGeometryChange: (() -> Void)?
    /// Main thread: the user picked mirrored (false) or extended (true) in the title bar.
    var onExtendedChange: ((Bool) -> Void)?

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    /// Layer-hosting view that keeps the Metal layer's drawable at the view's pixel size.
    private final class VideoView: NSView {
        var presenter: MetalPresenter?

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateDrawable()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateDrawable()
        }

        func updateDrawable() {
            guard let presenter, layer === presenter.layer, bounds.width > 0 else { return }
            let scale = window?.backingScaleFactor ?? 2
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            presenter.layer.frame = bounds
            CATransaction.commit()
            presenter.resize(sizePixels: CGSize(width: (bounds.width * scale).rounded(),
                                                height: (bounds.height * scale).rounded()), scale: scale)
        }
    }

    /// Clickable although the panel never becomes key.
    private final class TitleBarControl: NSSegmentedControl {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private let presenter: MetalPresenter
    private let window: Panel
    private let videoView = VideoView()
    private let modeControl = TitleBarControl(labels: ["Mirrored", "Extended"], trackingMode: .selectOne,
                                              target: nil, action: nil)

    var isVisible: Bool { window.isVisible }

    init(presenter: MetalPresenter) {
        self.presenter = presenter
        window = Panel(contentRect: CGRect(x: 0, y: 0, width: 480, height: 300),
                       styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .nonactivatingPanel],
                       backing: .buffered, defer: false)
        super.init()
        window.title = "MacBook"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.becomesKeyOnlyIfNeeded = true
        window.isReleasedWhenClosed = false
        window.animationBehavior = .utilityWindow
        window.backgroundColor = .black
        window.delegate = self
        videoView.presenter = presenter
        window.contentView = videoView

        // Mirrored / extended, at the right end of the title bar (the picture below keeps its size).
        modeControl.controlSize = .mini
        modeControl.font = .systemFont(ofSize: NSFont.systemFontSize(for: .mini))
        modeControl.selectedSegment = 0
        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        modeControl.setToolTip("Show the MacBook’s own screen", forSegment: 0)
        modeControl.setToolTip("Show an extra MacBook display. Its windows move to the MacBook when the picture closes", forSegment: 1)
        modeControl.sizeToFit()
        let holder = NSView(frame: CGRect(x: 0, y: 0, width: modeControl.frame.width + 6, height: modeControl.frame.height))
        modeControl.frame.origin = .zero
        holder.addSubview(modeControl)
        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = holder
        accessory.layoutAttribute = .right
        window.addTitlebarAccessoryViewController(accessory)
    }

    /// Main thread: shows the current choice in the title bar.
    func setExtended(_ extended: Bool) {
        modeControl.selectedSegment = extended ? 1 : 0
    }

    var extendedSelected: Bool { modeControl.selectedSegment == 1 }

    /// Self-test: picks a segment the way a click does. False if the control is not in the title bar.
    func selectForTest(extended: Bool) -> Bool {
        guard modeControl.window === window, !modeControl.isDescendant(of: videoView) else { return false }
        modeControl.selectedSegment = extended ? 1 : 0
        modeChanged()
        return true
    }

    @objc private func modeChanged() {
        onExtendedChange?(modeControl.selectedSegment == 1)
    }

    /// Main thread. `contentPoints` = size of the MacBook's main screen.
    func show(contentPoints: CGSize, localCursor: Bool) {
        let aspect = contentPoints.width / max(contentPoints.height, 1)
        videoView.layer = presenter.layer
        videoView.wantsLayer = true
        window.contentAspectRatio = contentPoints
        window.contentMinSize = CGSize(width: 240, height: (240 / aspect).rounded())

        if !window.setFrameUsingName(Self.autosaveName) || window.frame.width < 100 {
            // First time: a quarter of the screen's width, bottom right.
            let visible = (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
            let width = (visible.width / 4).rounded()
            let content = CGRect(x: 0, y: 0, width: width, height: (width / aspect).rounded())
            var frame = window.frameRect(forContentRect: content)
            frame.origin = CGPoint(x: visible.maxX - frame.width - 24, y: visible.minY + 24)
            window.setFrame(frame, display: false)
        }
        // Saved with another MacBook resolution: keep the width, fit the height to the picture.
        let content = window.contentRect(forFrameRect: window.frame)
        let fitted = CGSize(width: content.width, height: (content.width / aspect).rounded())
        if abs(fitted.height - content.height) > 0.5 {
            window.setContentSize(fitted)
        }
        window.setFrameAutosaveName(Self.autosaveName)

        let scale = window.backingScaleFactor
        let size = videoView.bounds.size
        presenter.configure(sizePixels: CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded()),
                            scale: scale, contentPoints: contentPoints, topInsetPoints: 0, localCursor: localCursor)
        videoView.updateDrawable()
        window.orderFrontRegardless()
        onGeometryChange?()
    }

    /// Main thread.
    func hide() {
        guard window.isVisible || videoView.layer === presenter.layer else { return }
        window.orderOut(nil)
        presenter.clear()
        if videoView.layer === presenter.layer { videoView.layer = CALayer() }
    }

    /// Main thread. Nil while hidden.
    var target: PiPTarget? {
        guard window.isVisible, window.isOnActiveSpace || window.collectionBehavior.contains(.canJoinAllSpaces),
              let primary = NSScreen.screens.first else { return nil }
        let height = primary.frame.height
        let content = window.contentRect(forFrameRect: window.frame)
        return PiPTarget(video: PiPGeometry.cgRect(fromCocoa: content, primaryHeight: height),
                         window: PiPGeometry.cgRect(fromCocoa: window.frame, primaryHeight: height),
                         windowID: CGWindowID(window.windowNumber))
    }

    // MARK: NSWindowDelegate

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onClose?()
        return false   // hidden (and reused) by the service instead
    }

    func windowDidMove(_ notification: Notification) { onGeometryChange?() }
    func windowDidResize(_ notification: Notification) { onGeometryChange?() }
    func windowDidChangeScreen(_ notification: Notification) { onGeometryChange?() }

    private static let autosaveName = "DuoDisplay.PiP"
}
