import AppKit
import CoreVideo
import os

/// `DuoDisplay --piptest [Ausgabedatei]`: the picture-in-picture window on this
/// Mac with a test picture – size, aspect ratio, video layer – and the detection of the pointer
/// moving into the picture (real event tap, posted pointer moves). Moves the pointer for about two
/// seconds and needs the Accessibility permission
/// (`open -n -W build/DuoDisplay.app --args --piptest /tmp/piptest.txt`; with DD_PIP_HOLD=5 the
/// window stays up with the test picture for 5 s before the pointer part).
enum PiPSelfTest {
    private static var lines: [String] = []
    private static var ok = true

    private static func say(_ line: String) {
        print(line)
        lines.append(line)
    }

    private static func check(_ name: String, _ condition: Bool) {
        say((condition ? "  ✓ " : "  ✗ ") + name)
        ok = ok && condition
    }

    static func run(output: String?) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Thread.detachNewThread {
            script()
            if let output { try? lines.joined(separator: "\n").write(toFile: output, atomically: true, encoding: .utf8) }
            DispatchQueue.main.async { exit(ok ? 0 : 1) }
        }
        app.run()
        exit(1)
    }

    private static func script() {
        say("DuoDisplay Bild-in-Bild-Selbsttest\n")
        let macPoints = CGSize(width: 1470, height: 956)
        let renderer = VideoRenderer()
        let presenter = renderer.presenter
        let pip = DispatchQueue.main.sync { PiPWindowController(presenter: presenter) }
        DispatchQueue.main.sync { pip.show(contentPoints: macPoints, localCursor: true) }
        Thread.sleep(forTimeInterval: 0.4)

        say("▶︎ Fenster")
        guard let target = DispatchQueue.main.sync(execute: { pip.target }) else {
            check("Fenster sichtbar", false)
            return
        }
        check("Fenster sichtbar", true)
        let aspect = target.video.width / target.video.height
        check(String(format: "Seitenverhältnis wie das MacBook (%.3f, erwartet %.3f)", aspect, macPoints.width / macPoints.height),
              abs(aspect - macPoints.width / macPoints.height) < 0.01)
        check("Titelleiste über dem Bild", target.window.minY < target.video.minY - 10)
        let layerOK = DispatchQueue.main.sync { () -> Bool in
            let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
            return abs(presenter.layer.frame.width - target.video.width) < 1
                && abs(presenter.layer.drawableSize.width - target.video.width * scale) < 2
        }
        check("Video-Ebene füllt das Fenster (auch in Pixeln)", layerOK)
        var picked: [Bool] = []
        let switchOK = DispatchQueue.main.sync { () -> Bool in
            pip.onExtendedChange = { picked.append($0) }
            return pip.selectForTest(extended: true) && pip.extendedSelected
                && pip.selectForTest(extended: false) && !pip.extendedSelected
        }
        check("Umschalter Gespiegelt/Erweitert in der Titelleiste meldet die Wahl (\(picked))",
              switchOK && picked == [true, false])
        check("Umschalter verkleinert das Bild nicht",
              DispatchQueue.main.sync { pip.target?.video } == target.video)

        // Test picture: horizontal gradient (NV12), the MacBook pointer in the middle.
        if let pb = testPicture(width: 1470, height: 956) {
            presenter.display(pb, captureNs: hostTimeNs())
        }
        let arrow = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: arrow.image.size)
        if let cg = arrow.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) {
            presenter.setCursorImage(cg, sizePoints: arrow.image.size, hotspot: arrow.hotSpot)
        }
        presenter.updateCursor(x: 735, y: 478, visible: true)
        Thread.sleep(forTimeInterval: 0.3)
        let video = presenter.syncVideo()
        check("Bild gezeichnet (\(video.draws) mit Video, \(video.textureFailures) Textur-Fehler)",
              video.draws > 0 && video.textureFailures == 0)
        let cursor = presenter.syncCursor()
        let expectedX = target.video.width / 2 - arrow.hotSpot.x * target.video.width / macPoints.width
        check(String(format: "MacBook-Zeiger in der Bildmitte (x %.1f, erwartet %.1f)", cursor.frame.minX, expectedX),
              !cursor.hidden && abs(cursor.frame.minX - expectedX) < 1)
        // Time for a look / a screenshot (DD_PIP_HOLD=Sekunden), test picture repeated like a stream.
        let hold = Double(ProcessInfo.processInfo.environment["DD_PIP_HOLD"] ?? "") ?? 0
        if hold > 0, let pb = testPicture(width: 1470, height: 956),
           let encoder = try? VideoEncoder(codec: .hevc, width: 1470, height: 956, fps: 30, bitrateMbps: 20) {
            // Through encoder + hardware decoder, like the real stream.
            let frameQueue = DispatchQueue(label: "piptest", qos: .userInteractive)
            encoder.onEncoded = { payload, _, _, _ in frameQueue.async { _ = renderer.handle(payload, lossBefore: false) } }
            let until = Date() + hold
            while Date() < until {
                frameQueue.sync { _ = encoder.encode(pb, captureNs: hostTimeNs()) }
                Thread.sleep(forTimeInterval: 1.0 / 30)
            }
            Thread.sleep(forTimeInterval: 0.2)
            let v = presenter.syncVideo()
            say("  (Halten: \(v.draws) Bilder mit Video gezeichnet, \(v.textureFailures) Textur-Fehler)")
        }
        say("\n▶︎ Zeiger ins Bild")
        guard AXIsProcessTrusted() else {
            say("  ✗ Bedienungshilfen-Freigabe fehlt (mit open -W build/DuoDisplay.app --args --piptest … starten)")
            ok = false
            return
        }
        let watcher = EdgeWatcher()
        let entered = OSAllocatedUnfairLock(initialState: [CGPoint]())
        watcher.onPiPEnter = { n, _ in entered.withLock { $0.append(n) } }
        guard watcher.install() else {
            check("Event-Tap", false)
            return
        }
        let start = CGEvent(source: nil)?.location ?? .zero
        defer { PointerWarp.move(to: start) }
        let v = target.video
        let left = CGPoint(x: v.minX - 30, y: v.midY)
        let inLeft = CGPoint(x: v.minX + 10, y: v.midY)
        func move(_ p: CGPoint, dragged: Bool = false) {
            CGEvent(mouseEventSource: nil, mouseType: dragged ? .leftMouseDragged : .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.06)
        }
        func takeEntries() -> [CGPoint] { entered.withLock { let e = $0; $0.removeAll(); return e } }

        move(inLeft)   // already inside when watching starts
        watcher.watch(nil, pip: target)
        move(CGPoint(x: inLeft.x + 20, y: inLeft.y))
        check("Zeiger schon im Bild beim Öffnen → noch nicht übernommen", takeEntries().isEmpty)

        move(left)
        move(inLeft)
        let over = EdgeWatcher.coveringWindows(inLeft, above: target.windowID)
        if !over.isEmpty { say("  Fenster über dem Bild: " + over.joined(separator: ", ")) }
        let fromLeft = takeEntries()
        check(String(format: "von links hinein → übernommen bei x %.2f, y %.2f",
                     fromLeft.first?.x ?? -1, fromLeft.first?.y ?? -1),
              fromLeft.count == 1 && fromLeft[0].x < 0.05 && abs(fromLeft[0].y - 0.5) < 0.05)

        move(CGPoint(x: inLeft.x + 15, y: inLeft.y))
        check("weitere Bewegung im Bild → nur einmal", takeEntries().isEmpty)

        watcher.watch(nil, pip: nil)
        watcher.watch(nil, pip: target)
        move(CGPoint(x: v.midX, y: v.maxY + 30))
        move(CGPoint(x: v.midX, y: v.maxY - 8))
        let fromBottom = takeEntries()
        check("von unten hinein → übernommen unten", fromBottom.count == 1 && (fromBottom.first?.y ?? 0) > 0.95)

        watcher.watch(nil, pip: nil)
        watcher.watch(nil, pip: target)
        move(CGPoint(x: v.midX, y: target.window.minY + 5))   // title bar
        move(CGPoint(x: v.midX, y: v.minY + 6))
        let fromTop = takeEntries()
        check("von der Titelleiste hinein → übernommen oben", fromTop.count == 1 && (fromTop.first?.y ?? 1) < 0.05)

        watcher.watch(nil, pip: nil)
        watcher.watch(nil, pip: target)
        move(CGPoint(x: v.maxX + 30, y: v.midY))
        move(CGPoint(x: v.maxX - 2, y: v.midY))
        check("im Rand zum Größe-Ändern → nicht übernommen", takeEntries().isEmpty)
        move(CGPoint(x: v.maxX - 10, y: v.midY), dragged: true)
        check("mit gedrückter Taste (Ziehen) → nicht übernommen", takeEntries().isEmpty)
        move(CGPoint(x: v.maxX - 12, y: v.midY))
        let fromRight = takeEntries()
        check("danach ohne Taste → übernommen rechts", fromRight.count == 1 && (fromRight.first?.x ?? 0) > 0.95)

        // A menu-like window above the picture: no takeover under it.
        let cover = DispatchQueue.main.sync { () -> NSWindow in
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let w = NSWindow(contentRect: CGRect(x: v.minX + 40, y: primaryHeight - v.minY - 120, width: 160, height: 100),
                             styleMask: .borderless, backing: .buffered, defer: false)
            w.level = .popUpMenu
            w.backgroundColor = .systemBlue
            w.orderFrontRegardless()
            return w
        }
        Thread.sleep(forTimeInterval: 0.3)
        watcher.watch(nil, pip: nil)
        watcher.watch(nil, pip: target)
        move(left)
        move(CGPoint(x: v.minX + 100, y: v.minY + 60))   // under the cover window
        check("unter einem Menü über dem Bild → nicht übernommen", takeEntries().isEmpty)
        move(CGPoint(x: v.minX + 100, y: v.maxY - 30))   // free part of the picture
        check("daneben im freien Teil → übernommen", takeEntries().count == 1)
        DispatchQueue.main.sync { cover.orderOut(nil) }
        watcher.watch(nil, pip: nil)

        say("\n▶︎ Größe ändern")
        DispatchQueue.main.sync {
            if let window = NSApp.windows.first(where: { $0.windowNumber == Int(target.windowID) }) {
                window.setContentSize(CGSize(width: 600, height: 600 * macPoints.height / macPoints.width))
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let resized = DispatchQueue.main.sync { pip.target }
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        check("neue Größe übernommen", abs((resized?.video.width ?? 0) - 600) < 1)
        check("Video-Ebene mitgewachsen", DispatchQueue.main.sync {
            abs(presenter.layer.drawableSize.width - 600 * scale) < 2 && abs(presenter.layer.frame.width - 600) < 1
        })
        if let resized {
            let s = PiPGeometry.motionScale(macPoints: macPoints, video: resized.video)
            check(String(format: "Zeigertempo im Bild: ×%.2f", s), abs(s - 1470.0 / 600) < 0.01)
        }

        DispatchQueue.main.sync { pip.hide() }
        check("Schließen blendet das Fenster aus", DispatchQueue.main.sync { pip.target == nil })
        say(ok ? "\nERGEBNIS: OK" : "\nERGEBNIS: FEHLER")
    }

    private static func testPicture(width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferMetalCompatibilityKey: true]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        CVPixelBufferLockBaseAddress(pb, [])
        let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
        for row in 0..<height {
            for col in 0..<width { y[row * yRow + col] = UInt8(16 + col * 219 / width) }
        }
        let c = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self)
        let cRow = CVPixelBufferGetBytesPerRowOfPlane(pb, 1)
        for row in 0..<(height / 2) {
            for col in 0..<(width / 2) {
                c[row * cRow + col * 2] = 160        // Cb: a little blue
                c[row * cRow + col * 2 + 1] = UInt8(96 + row * 64 / (height / 2))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        return pb
    }
}
