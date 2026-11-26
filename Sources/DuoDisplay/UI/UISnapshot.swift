import AppKit
import SwiftUI

/// `DuoDisplay --uisnapshot <dir>`: renders every window (mode picker, MacBook, iMac, pairing
/// code) offscreen in light and dark mode as PNGs, for reviewing the design without two Macs.
/// Nothing connects: the sessions are created but never started.
/// With `--onscreen` each window is shown briefly and photographed with `screencapture` – the
/// only way to see Liquid Glass, which the WindowServer draws (needs Screen Recording permission
/// for the calling app, e.g. Terminal).
enum UISnapshot {
    static func run(output: String, onscreen: Bool = false) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        SenderDefaults.register()

        let sender = SenderSession()
        let receiver = ReceiverService()
        let prompt = PairingPrompt()
        prompt.show(code: "482913", peerName: "MacBook Pro", note: nil, onConfirm: {}, onCancel: {})
        prompt.close()

        let pages: [(String, AnyView, CGSize)] = [
            ("1-mode", AnyView(ModePicker(mode: .constant(""))), CGSize(width: 700, height: 560)),
            ("2-macbook", AnyView(SenderView(session: sender, onBack: {})), CGSize(width: 640, height: 1700)),
            ("3-imac", AnyView(ReceiverView(service: receiver, onBack: {})), CGSize(width: 620, height: 1150)),
            ("4-pairing", AnyView(PairingPromptView(prompt: prompt)), CGSize(width: 400, height: 380)),
        ]
        try? FileManager.default.createDirectory(atPath: output, withIntermediateDirectories: true)

        for (appearanceName, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            for (name, view, size) in pages {
                let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                                      styleMask: [.titled, .closable, .miniaturizable],
                                      backing: .buffered, defer: false)
                window.title = "DuoDisplay"
                window.appearance = NSAppearance(named: appearanceName)
                let hosting = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                hosting.sceneBridgingOptions = [.toolbars, .title]
                window.contentView = hosting
                let path = "\(output)/\(name)-\(suffix).png"
                if onscreen {
                    window.center()
                    window.orderFrontRegardless()
                    RunLoop.main.run(until: Date().addingTimeInterval(1.2))
                    let capture = Process()
                    capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                    capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), path]
                    try? capture.run()
                    capture.waitUntilExit()
                    print(path)
                    window.orderOut(nil)
                    continue
                }
                window.setFrameOrigin(NSPoint(x: -6000, y: -6000))
                window.orderFront(nil)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))

                guard let frameView = window.contentView?.superview else { continue }
                let bounds = frameView.bounds
                guard let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) else { continue }
                frameView.cacheDisplay(in: bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                print(path)
                window.orderOut(nil)
            }
        }
        exit(0)
    }
}
