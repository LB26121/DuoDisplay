import Foundation
import AppKit
import VideoToolbox
import CoreMedia
import Network
import CryptoKit
import os

/// `DuoDisplay --selftest`: runs the whole video path on this Mac without screen capture:
/// synthetic frames → hardware encoder → AES-GCM → UDP (loopback, with simulated packet loss)
/// → reassembly → keyframe/loss handling → hardware decoder. Prints latency numbers.
enum SelfTest {
    static func run() -> Bool {
        print("DuoDisplay Selbsttest (Encoder → UDP → Reassembly → Decoder, Loopback)\n")
        var ok = true
        let env = ProcessInfo.processInfo.environment
        if let w = env["DD_W"].flatMap(Int.init), let h = env["DD_H"].flatMap(Int.init) {
            let fps = env["DD_FPS"].flatMap(Int.init) ?? 60
            return runOne(codec: env["DD_HEVC"] != nil ? .hevc : .h264, width: w, height: h, fps: fps, seconds: 3, datagram: 1400, dropEvery: 0)
        }
        // Retina 2× / 1.5× / 1× of a 14" MacBook Pro screen, HEVC (default), with simulated loss.
        ok = runOne(codec: .hevc, width: 3024, height: 1890, fps: 60, seconds: 4, datagram: 1400, dropEvery: 90) && ok
        ok = runOne(codec: .hevc, width: 2268, height: 1418, fps: 60, seconds: 3, datagram: 1400, dropEvery: 0) && ok
        ok = runOne(codec: .hevc, width: 1512, height: 944, fps: 120, seconds: 3, datagram: 8900, dropEvery: 0) && ok
        ok = runOne(codec: .h264, width: 3024, height: 1890, fps: 60, seconds: 3, datagram: 8900, dropEvery: 90) && ok
        // ProRes: every frame is a keyframe, so a loss costs exactly one frame.
        ok = runOne(codec: .prores, width: 3024, height: 1890, fps: 60, seconds: 3, datagram: 8900, dropEvery: 90) && ok
        ok = runOne(codec: .prores, width: 3024, height: 1890, fps: 60, seconds: 2, datagram: 1400, dropEvery: 0) && ok
        print(ok ? "\nERGEBNIS: OK" : "\nERGEBNIS: FEHLER")
        return ok
    }

    /// `DuoDisplay --displaytest`: creates the virtual display for a 14" MacBook Pro (1512×945 pt, 2×)
    /// for ~2 s and checks that macOS selected the right HiDPI mode.
    static func runVirtualDisplay() -> Bool {
        let (ptW, ptH, pxW, pxH) = (1512, 944, 3024, 1888)
        var ok = false
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            guard let display = VirtualDisplay(name: "DuoDisplay Test", serial: 42, pixelWidth: pxW, pixelHeight: pxH,
                                               pointWidth: ptW, pointHeight: ptH, refreshRate: 120, hiDPI: true, placeRight: true) else {
                print("✗ CGVirtualDisplay konnte nicht erstellt werden"); done.signal(); return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                let id = display.displayID
                if let mode = CGDisplayCopyDisplayMode(id) {
                    print("Virtueller Bildschirm \(id): \(mode.width)×\(mode.height) pt, \(mode.pixelWidth)×\(mode.pixelHeight) px, \(mode.refreshRate) Hz")
                    ok = mode.pixelWidth == pxW && mode.pixelHeight == pxH && mode.width == ptW && mode.height == ptH && mode.refreshRate == 120
                }
                let bounds = CGDisplayBounds(id)
                let main = CGDisplayBounds(CGMainDisplayID())
                print("Position im Bildschirmverbund: \(bounds) (Hauptbildschirm \(main))")
                if bounds.minX != main.maxX { print("✗ nicht rechts neben dem Hauptbildschirm"); ok = false; done.signal(); return }
                print(ok ? "✓ HiDPI-Modus korrekt" : "✗ Modus weicht ab")
                withExtendedLifetime(display) {}
                done.signal()
            }
        }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        return ok
    }

    /// `DuoDisplay --inputtest`: checks that serializing a CGEvent (what the receiver sends) and
    /// recreating it (what the sender posts) keeps every field gestures and scrolling depend on.
    static func runInputSerialization() -> Bool {
        var ok = true
        func check(_ name: String, _ condition: Bool) {
            print((condition ? "  ✓ " : "  ✗ ") + name)
            ok = ok && condition
        }
        func roundtrip(_ e: CGEvent) -> CGEvent? {
            guard let data = e.data as Data? else { return nil }
            return CGEvent(withDataAllocator: kCFAllocatorDefault, data: data as CFData)
        }

        print("Scrollen mit Trackpad-Phasen und Schwung:")
        let scroll = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -12, wheel2: 3, wheel3: 0)!
        scroll.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        scroll.setIntegerValueField(.scrollWheelEventScrollPhase, value: 2)      // changed
        scroll.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 0)
        scroll.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -12.75)
        if let r = roundtrip(scroll) {
            check("Typ", r.type == .scrollWheel)
            check("kontinuierlich (Trackpad)", r.getIntegerValueField(.scrollWheelEventIsContinuous) == 1)
            check("Scroll-Phase", r.getIntegerValueField(.scrollWheelEventScrollPhase) == 2)
            check("Pixel-Delta", r.getIntegerValueField(.scrollWheelEventPointDeltaAxis1) == -12)
            check("Sub-Pixel-Delta", abs(r.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1) + 12.75) < 0.01)
        } else { check("Serialisierung", false) }

        print("Doppelklick und Ziehen:")
        let click = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left)!
        click.setIntegerValueField(.mouseEventClickState, value: 2)
        click.setDoubleValueField(.mouseEventPressure, value: 0.8)
        if let r = roundtrip(click) {
            check("Klickanzahl 2", r.getIntegerValueField(.mouseEventClickState) == 2)
            check("Druck (Force Touch)", abs(r.getDoubleValueField(.mouseEventPressure) - 0.8) < 0.01)
        } else { check("Serialisierung", false) }
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged, mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left)!
        drag.setIntegerValueField(.mouseEventDeltaX, value: 3)
        drag.setIntegerValueField(.mouseEventDeltaY, value: -2)
        if let r = roundtrip(drag) {
            check("relative Bewegung", r.getIntegerValueField(.mouseEventDeltaX) == 3 && r.getIntegerValueField(.mouseEventDeltaY) == -2)
        } else { check("Serialisierung", false) }

        print("Tastatur mit Modifiern:")
        let key = CGEvent(keyboardEventSource: nil, virtualKey: 0x30, keyDown: true)!   // Tab
        key.flags = [.maskCommand]
        if let r = roundtrip(key) {
            check("⌘-Tab", r.getIntegerValueField(.keyboardEventKeycode) == 0x30 && r.flags.contains(.maskCommand))
        } else { check("Serialisierung", false) }

        print("Trackpad-Geste (privater Event-Typ 29, Felder wie bei einer Dock-Wischgeste):")
        let gesture = CGEvent(source: nil)!
        gesture.type = CGEventType(rawValue: 29)!
        let fields: [(UInt32, Int64)] = [(110, 23), (132, 1), (134, 2)]
        for (field, value) in fields { gesture.setIntegerValueField(CGEventField(rawValue: field)!, value: value) }
        gesture.setDoubleValueField(CGEventField(rawValue: 124)!, value: 0.42)
        if let r = roundtrip(gesture) {
            check("Typ 29", r.type.rawValue == 29)
            check("Gesten-Subtyp und Phase", fields.allSatisfy { r.getIntegerValueField(CGEventField(rawValue: $0.0)!) == $0.1 })
            check("Gesten-Fortschritt", abs(r.getDoubleValueField(CGEventField(rawValue: 124)!) - 0.42) < 0.001)
        } else { check("Serialisierung", false) }

        print("Lautstärketasten (bleiben im Bildschirm-Modus auf dem iMac):")
        func auxKey(_ key: Int, down: Bool = true) -> CGEvent? {
            NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                               context: nil, subtype: 8, data1: (key << 16) | ((down ? 0xA : 0xB) << 8), data2: -1)?.cgEvent
        }
        func isVolume(_ e: CGEvent?) -> Bool { e.map { VolumeKey.matches(type: $0.type.rawValue, event: $0) } ?? false }
        check("lauter / leiser / stumm (gedrückt und losgelassen)",
              isVolume(auxKey(0)) && isVolume(auxKey(1)) && isVolume(auxKey(7)) && isVolume(auxKey(0, down: false)))
        check("Wiedergabe, Helligkeit, Tastaturlicht werden weitergeleitet",
              !isVolume(auxKey(16)) && !isVolume(auxKey(2)) && !isVolume(auxKey(3)) && !isVolume(auxKey(21)))
        check("Tastencodes lauter / leiser / stumm", [0x48, 0x49, 0x4A].allSatisfy {
            isVolume(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode($0), keyDown: true)) })
        check("normale Taste (Tab, F11) wird weitergeleitet",
              !isVolume(key) && !isVolume(CGEvent(keyboardEventSource: nil, virtualKey: 0x67, keyDown: true)))
        if let up = auxKey(0), let r = roundtrip(up) {
            check("CGEvent-Typ 14 nach Serialisierung erkannt", r.type.rawValue == VolumeKey.systemDefined && isVolume(r))
        } else { check("Serialisierung", false) }

        print(ok ? "ERGEBNIS: OK" : "ERGEBNIS: FEHLER")
        return ok
    }

    /// `DuoDisplay --rendertest`: encoder → VideoRenderer (VideoToolbox decode) → MetalPresenter,
    /// incl. pointer drawing. Measures frame submitted → handed to the display.
    static func runRender() -> Bool { runRender(window: nil, fps: 60, cursorUpdatesPerFrame: 1) }

    /// `DuoDisplay --rendertest --window`: same path, but presented in a real on-screen window at
    /// 60 fps with a pointer moving at 480 Hz (a fast mouse), like a live stream, then at 120 fps.
    /// Off-screen layers never wait for the window server, so only this variant shows whether latency
    /// piles up in the render queue, or whether pointer moves make video frames wait for a drawable.
    static func runRenderWindowed() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let window = NSWindow(contentRect: CGRect(x: 80, y: 80, width: 756, height: 473),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.isOpaque = true
        window.backgroundColor = .black
        Thread {
            var ok = runRender(window: window, fps: 60, cursorUpdatesPerFrame: 8)
            ok = runRender(window: window, fps: 120, cursorUpdatesPerFrame: 2) && ok
            DispatchQueue.main.async { exit(ok ? 0 : 1) }
        }.start()
        app.run()
        exit(1)
    }

    private static func runRender(window: NSWindow?, fps: Int, cursorUpdatesPerFrame: Int) -> Bool {
        let (width, height) = (3024, 1890)
        let codec: VideoCodec = CommandLine.arguments.contains("--prores") ? .prores : .hevc
        let vsync = ProcessInfo.processInfo.environment["DD_VSYNC"] != "0"
        print("Empfangspfad: \(codec.label) \(width)×\(height)@\(fps) → Hardware-Decoder → Metal (\(vsync ? "mit" : "ohne") V-Sync)"
              + (window == nil ? "" : ", im Fenster, Zeiger \(fps * cursorUpdatesPerFrame) Hz"))
        let renderer = VideoRenderer()
        let presenter = renderer.presenter
        presenter.vsync = vsync
        if let window {
            DispatchQueue.main.sync {
                let view = NSView()
                view.layer = presenter.layer
                view.wantsLayer = true
                window.contentView = view
                window.orderFrontRegardless()
                let scale = window.backingScaleFactor
                presenter.configure(sizePixels: CGSize(width: window.frame.width * scale, height: window.frame.height * scale),
                                    scale: scale, contentPoints: CGSize(width: 1512, height: 945), topInsetPoints: 0,
                                    localCursor: true)
            }
        } else {
            presenter.configure(sizePixels: CGSize(width: 4480, height: 2520), scale: 2,
                                contentPoints: CGSize(width: 1512, height: 945), topInsetPoints: 0, localCursor: true)
        }
        let latencies = OSAllocatedUnfairLock(initialState: [Double]())
        presenter.onPresented = { captureNs in
            latencies.withLock { $0.append(Double(hostTimeNs() &- captureNs) / 1_000_000) }
        }
        // Pointer image + movement
        let arrow = NSCursor.arrow
        var rect = CGRect(origin: .zero, size: arrow.image.size)
        // Without a running NSApplication the system arrow may not render; a plain square does the job.
        let fallback: CGImage? = {
            let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
            ctx?.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx?.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            return ctx?.makeImage()
        }()
        if let cg = arrow.image.cgImage(forProposedRect: &rect, context: nil, hints: nil) ?? fallback {
            presenter.setCursorImage(cg, sizePoints: arrow.image.size, hotspot: arrow.hotSpot)
        }

        guard let encoder = try? VideoEncoder(codec: codec, width: width, height: height, fps: fps, bitrateMbps: 150) else {
            print("  ✗ Encoder"); return false
        }
        let frameQueue = DispatchQueue(label: "rendertest", qos: .userInteractive)
        encoder.onEncoded = { payload, _, _, _ in
            frameQueue.async { _ = renderer.handle(payload, lossBefore: false) }
        }
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        let total = fps * 2
        for i in 0..<total {
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb!, 0)!
            memset(y, Int32(40 + (i * 3) % 180), CVPixelBufferGetBytesPerRowOfPlane(pb!, 0) * height)
            memset(CVPixelBufferGetBaseAddressOfPlane(pb!, 1)!, 128, CVPixelBufferGetBytesPerRowOfPlane(pb!, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(pb!, [])
            frameQueue.sync { _ = encoder.encode(pb!, captureNs: hostTimeNs()) }
            for k in 0..<cursorUpdatesPerFrame {
                presenter.updateCursor(x: CGFloat(100 + (i * cursorUpdatesPerFrame + k) % 1300), y: 300, visible: true)
                Thread.sleep(forTimeInterval: 1.0 / Double(fps * cursorUpdatesPerFrame))
            }
        }
        Thread.sleep(forTimeInterval: 0.3)
        let rendered = presenter.sync()
        let pointer = presenter.syncCursor()
        // Last position: x = 100 + (n - 1) % 1300 points, y = 300, arrow hotspot; content 1512×945 points.
        let lastX = CGFloat(100 + (total * cursorUpdatesPerFrame - 1) % 1300)
        let bounds = window.map { w in DispatchQueue.main.sync { w.contentView!.bounds.size } } ?? CGSize(width: 2240, height: 1260)
        let fitP = min(bounds.width / 1512, bounds.height / 945)
        let originX = (bounds.width - 1512 * fitP) / 2, originTop = (bounds.height - 945 * fitP) / 2
        let expectedX = originX + (lastX - arrow.hotSpot.x) * fitP
        let expectedTop = originTop + (300 - arrow.hotSpot.y) * fitP
        let actualTop = bounds.height - pointer.frame.maxY   // layer: bottom-left origin
        let pointerOK = !pointer.hidden && abs(pointer.frame.minX - expectedX) < 0.5 && abs(actualTop - expectedTop) < 0.5
        print(String(format: "  Zeiger-Ebene: %d Updates, zuletzt bei (%.1f, %.1f) pt von oben links, erwartet (%.1f, %.1f) %@",
                     pointer.updates, pointer.frame.minX, actualTop, expectedX, expectedTop, pointerOK ? "✓" : "✗"))
        let inOrder = latencies.withLock { $0 }
        let l = inOrder.sorted()
        let avg = l.isEmpty ? .nan : l.reduce(0, +) / Double(l.count)
        let p95 = l.isEmpty ? .nan : l[min(l.count - 1, l.count * 95 / 100)]
        let tail = inOrder.suffix(max(1, inOrder.count / 5))
        let tailAvg = tail.reduce(0, +) / Double(tail.count)
        print("  Bilder an GPU übergeben: \(l.count) von \(total) Video-Frames, Render-Durchläufe gesamt \(rendered)")
        print(String(format: "  Frame→Bildschirm (Encode + Decode + Render): Ø %.2f ms · p50 %.2f · p95 %.2f · max %.2f ms · letzte 20 %% Ø %.2f ms",
                     avg, l.isEmpty ? .nan : l[l.count / 2], p95, l.last ?? .nan, tailAvg))
        let ok: Bool
        if window == nil {
            ok = l.count >= total * 9 / 10 && pointerOK
        } else {
            // Frames may be skipped (newest wins), but delay must stay bounded and must not grow.
            ok = l.count >= total / 3 && p95 < 40 && tailAvg < 40 && pointerOK
        }
        print(ok ? "ERGEBNIS: OK" : "ERGEBNIS: FEHLER")
        return ok
    }

    private struct Results {
        var decoded = 0
        var decodeErrors = 0
        var latencies: [Double] = []
        var keyframeRequests = 0
        var lostEvents = 0
    }

    private static func runOne(codec: VideoCodec, width: Int, height: Int, fps: Int,
                               seconds: Double, datagram: Int, dropEvery: Int) -> Bool {
        let label = "\(codec.label) \(width)×\(height)@\(fps), \(datagram) B/Paket" + (dropEvery > 0 ? ", Verlust alle \(dropEvery) Frames" : "")
        print("▶︎ \(label)")

        let results = OSAllocatedUnfairLock(initialState: Results())
        let frameQueue = DispatchQueue(label: "selftest.frames", qos: .userInteractive)

        // Receiver
        let receiver = UDPReceiver()
        do { try receiver.start() } catch { print("  UDP: \(error)"); return false }
        let mediaKey = SymmetricKey(size: .bits256)   // sealed like a real connection
        receiver.setOpener(MediaOpener(key: mediaKey))
        let assembler = FrameAssembler()
        let gate = FrameGate()
        var decoder: VTDecompressionSession?
        var decoderFormat: CMFormatDescription?

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(codec: codec, width: width, height: height, fps: fps, bitrateMbps: 120)
        } catch { print("  \(error.localizedDescription)"); return false }
        print("  Hardware-Encoder: \(encoder.hardware ? "ja" : "nein") · Low-Latency-Ratensteuerung: \(encoder.lowLatencyMode ? "ja" : "nein")")

        var lastKeyRequest: UInt64 = 0
        let requestKeyframe = {
            let now = hostTimeNs()
            guard now &- lastKeyRequest > 100_000_000 else { return }
            lastKeyRequest = now
            results.withLock { $0.keyframeRequests += 1 }
            frameQueue.async { encoder.requestKeyframe() }
        }

        assembler.onLoss = { results.withLock { $0.lostEvents += 1 }; gate.markLoss(); requestKeyframe() }
        assembler.onFrame = { data, lost in
            if lost { results.withLock { $0.lostEvents += 1 } }
            switch gate.process(data, lossBefore: lost) {
            case .invalid:
                results.withLock { $0.decodeErrors += 1 }
            case .needKeyframe:
                requestKeyframe()
            case let .sample(sample, captureNs, _):
                guard let format = CMSampleBufferGetFormatDescription(sample) else { return }
                if decoder == nil || decoderFormat.map({ !CMFormatDescriptionEqual($0, otherFormatDescription: format) }) ?? true {
                    if let d = decoder { VTDecompressionSessionInvalidate(d) }
                    decoder = nil
                    VTDecompressionSessionCreate(allocator: nil, formatDescription: format, decoderSpecification: nil,
                                                 imageBufferAttributes: nil, outputCallback: nil,
                                                 decompressionSessionOut: &decoder)
                    decoderFormat = format
                }
                guard let decoder else { results.withLock { $0.decodeErrors += 1 }; return }
                let status = VTDecompressionSessionDecodeFrame(decoder, sampleBuffer: sample, flags: [], infoFlagsOut: nil) {
                    status, _, image, _, _ in
                    let done = hostTimeNs()
                    results.withLock {
                        if status == noErr, image != nil {
                            $0.decoded += 1
                            $0.latencies.append(Double(done &- captureNs) / 1_000_000)
                        } else {
                            $0.decodeErrors += 1
                        }
                    }
                }
                if status != noErr { results.withLock { $0.decodeErrors += 1 }; gate.markLoss(); requestKeyframe() }
            }
        }
        receiver.onDatagram = { buf in
            guard buf.count > DD.chunkHeaderSize, buf[0] == DD.magic, buf[1] == 1 else { return }
            assembler.ingest(buf, now: hostTimeNs())
        }
        var lastTick: UInt64 = 0
        receiver.onTick = {
            let now = hostTimeNs()
            if now &- lastTick > 5_000_000 { lastTick = now; assembler.expireStale(now: now) }
        }

        // Sender
        let sender = UDPVideoSender(host: "127.0.0.1", port: receiver.port, session: 1, datagramSize: datagram, interface: nil,
                                    sealer: MediaSealer(key: mediaKey))
        if dropEvery > 0 {
            sender.dropFilter = { frameId, index in frameId % UInt32(dropEvery) == 0 && index == 0 }
        }
        let sentFrames = OSAllocatedUnfairLock(initialState: (frames: 0, bytes: 0, encodeNs: UInt64(0), keyframes: 0))
        encoder.onEncoded = { payload, keyframe, encodeNs, _ in
            sender.send(payload)
            sentFrames.withLock { $0.frames += 1; $0.bytes += payload.count; $0.encodeNs += encodeNs; if keyframe { $0.keyframes += 1 } }
        }

        // Synthetic content: a diagonal gradient that scrolls, plus a moving block.
        var pool: CVPixelBufferPool?
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width, kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pool)
        guard let pool else { print("  PixelBufferPool fehlgeschlagen"); return false }
        let pattern = (0..<(width + 512)).map { UInt8(truncatingIfNeeded: $0) }

        let total = Int(seconds * Double(fps))
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: frameQueue)
        var frameIndex = 0
        let finished = DispatchSemaphore(value: 0)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(1_000_000_000 / fps), leeway: .microseconds(500))
        timer.setEventHandler {
            guard frameIndex < total else { timer.cancel(); finished.signal(); return }
            var pb: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
            guard let pb else { return }
            CVPixelBufferLockBaseAddress(pb, [])
            let y = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
            let yStride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
            let shift = (frameIndex * 6) % 256
            pattern.withUnsafeBufferPointer { p in
                for row in 0..<height {
                    (y + row * yStride).update(from: p.baseAddress! + ((row + shift) & 255), count: width)
                }
            }
            let bx = (frameIndex * 23) % (width - 200), by = (frameIndex * 11) % (height - 200)
            for row in by..<(by + 200) { (y + row * yStride + bx).update(repeating: 235, count: 200) }
            let uv = CVPixelBufferGetBaseAddressOfPlane(pb, 1)!
            memset(uv, 128, CVPixelBufferGetBytesPerRowOfPlane(pb, 1) * height / 2)
            CVPixelBufferUnlockBaseAddress(pb, [])
            encoder.encode(pb, captureNs: hostTimeNs())
            frameIndex += 1
        }
        timer.resume()
        finished.wait()
        Thread.sleep(forTimeInterval: 0.3)
        receiver.stop()
        sender.cancel()
        encoder.invalidate()
        Thread.sleep(forTimeInterval: 0.05)

        let r = results.withLock { $0 }
        let s = sentFrames.withLock { $0 }
        let sorted = r.latencies.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? .nan : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let avg = sorted.isEmpty ? .nan : sorted.reduce(0, +) / Double(sorted.count)
        print(String(format: "  gesendet %d Frames (%d Keyframes), %.1f Mbit/s, Encoder Ø %.2f ms",
                     s.frames, s.keyframes, Double(s.bytes) * 8 / 1_000_000 / seconds,
                     s.frames > 0 ? Double(s.encodeNs) / Double(s.frames) / 1_000_000 : 0))
        print("  dekodiert \(r.decoded), Decoderfehler \(r.decodeErrors), Verlustereignisse \(r.lostEvents), Keyframe-Anfragen \(r.keyframeRequests)")
        print(String(format: "  Latenz Frame→dekodiert: Ø %.2f ms · p50 %.2f · p95 %.2f · max %.2f ms",
                     avg, pct(0.5), pct(0.95), sorted.last ?? .nan))

        // Every frame except those dropped and the ones until the next keyframe must arrive.
        // Intra-only (ProRes): a loss may only cost the lost frame itself, no wait for a keyframe.
        let expectedMin = Int(Double(s.frames) * (dropEvery > 0 && !codec.isIntraOnly ? 0.85 : 0.97))
        let pass = r.decodeErrors == 0 && r.decoded >= expectedMin && avg < 30
        print(pass ? "  ✓ bestanden\n" : "  ✗ nicht bestanden (erwartet ≥ \(expectedMin) dekodierte Frames)\n")
        return pass
    }
}
