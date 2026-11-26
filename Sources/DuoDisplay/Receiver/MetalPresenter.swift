import Foundation
import Metal
import QuartzCore
import CoreVideo
import os

/// Puts decoded frames on screen with the least possible delay:
///  • V-Sync is a setting (`vsync`, on by default). Off, a frame is presented the moment it is
///    decoded – but the stream window covers the whole screen, so macOS scans our drawable out
///    directly and a present in the middle of a refresh shows the top of one frame above the
///    bottom of the next: horizontal tear lines whenever the picture moves fast (scrolling).
///    On, a frame waits for the next refresh (Ø half a refresh, ~8 ms at 60 Hz) and is shown whole.
///    Only two drawables then: at most one frame waits for V-Sync, so the delay cannot build up,
///    and the next render picks the newest decoded frame once a drawable frees.
///  • NV12 → RGB conversion in a tiny shader (no extra copies).
///  • "Newest wins": at most one render is ever scheduled. It first waits for a drawable and only
///    then picks up the latest decoded frame.
///  • The mouse pointer is NOT drawn with Metal but is a plain CALayer above the video that only
///    gets moved. The window server frees only about two drawables per display refresh (measured on
///    a 60 Hz iMac); when every pointer move (a mouse reports 125–1000 positions/s) rendered and
///    presented a whole 4.5K frame, all drawables were always busy and each new video frame first
///    waited for one – Ø ~6 ms. Now video renders only for video frames (no waiting at 60 fps), and
///    a pointer move costs one tiny layer transaction instead of a frame.
/// Video rendering happens on one serial high-priority queue, pointer updates on another.
final class MetalPresenter {
    let layer = CAMetalLayer()

    /// Called after a video frame was handed to the GPU (render queue): (captureNs of that frame).
    var onPresented: ((UInt64) -> Void)?

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let videoPipeline: MTLRenderPipelineState
    private var textureCache: CVMetalTextureCache?
    private let queue = DispatchQueue(label: "duodisplay.render", qos: .userInteractive)

    /// Written from any thread, consumed by the next render.
    private struct Latest {
        var pixelBuffer: CVPixelBuffer?
        var captureNs: UInt64 = 0
        var renderScheduled = false
    }
    private let latest = OSAllocatedUnfairLock(uncheckedState: Latest())

    // State (render queue only)
    private var lumaTexture: CVMetalTexture?
    private var chromaTexture: CVMetalTexture?
    private var contentPoints = CGSize(width: 16, height: 10)
    private var topInsetPixels: CGFloat = 0
    private var active = false
    /// A decoded frame is in the textures but could not be shown yet (no drawable).
    private var redrawPending = false

    private(set) var renderedFrames = 0   // render queue; used by the self test
    private(set) var videoDraws = 0       // render queue; renders that drew a picture (self test)
    private(set) var textureFailures = 0  // render queue; frames whose Metal textures could not be made

    /// Wait for V-Sync before a frame is shown (no tearing). Any thread.
    var vsync: Bool {
        get { vsyncBox.withLock { $0 } }
        set {
            vsyncBox.withLock { $0 = newValue }
            queue.async { [self] in applyVsync(newValue) }
        }
    }
    private let vsyncBox = OSAllocatedUnfairLock(initialState: true)

    // MARK: Pointer layer

    /// Where the video sits inside the layer, in layer points (bottom-left origin unless the layer
    /// is geometry-flipped), and the pointer's state. Written from any thread.
    private struct Pointer {
        var position = CGPoint.zero      // streamed display points, top-left origin
        var visible = false
        var enabled = true               // "draw pointer locally"
        var active = false               // stream window shown
        var hasImage = false
        var sizePoints = CGSize.zero
        var hotspot = CGPoint.zero
        var boundsPoints = CGSize.zero   // whole layer
        var contentPoints = CGSize(width: 16, height: 10)
        var topInsetPoints: CGFloat = 0
        var updateScheduled = false
    }
    private let pointer = OSAllocatedUnfairLock(uncheckedState: Pointer())
    private let cursorLayer = CALayer()
    private let cursorQueue = DispatchQueue(label: "duodisplay.cursor", qos: .userInteractive)
    private(set) var cursorFrame = CGRect.zero   // cursor queue; used by the self test
    private(set) var cursorUpdates = 0           // cursor queue; used by the self test

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let commandQueue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        do {
            let library = try device.makeLibrary(source: Self.shaderSource, options: nil)
            let video = MTLRenderPipelineDescriptor()
            video.vertexFunction = library.makeFunction(name: "quad_vs")
            video.fragmentFunction = library.makeFunction(name: "nv12_fs")
            video.colorAttachments[0].pixelFormat = .bgra8Unorm
            videoPipeline = try device.makeRenderPipelineState(descriptor: video)
        } catch {
            NSLog("DuoDisplay: Metal shader failed: \(error)")
            return nil
        }
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.displaySyncEnabled = true         // see `vsync`
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.presentsWithTransaction = false
        layer.backgroundColor = CGColor(gray: 0, alpha: 1)
        layer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "frame": NSNull()]

        cursorLayer.isHidden = true
        cursorLayer.contentsGravity = .resize
        cursorLayer.magnificationFilter = .linear
        cursorLayer.minificationFilter = .linear
        cursorLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull(), "frame": NSNull(),
                               "hidden": NSNull(), "contentsScale": NSNull()]
        cursorLayer.zPosition = 1
        layer.addSublayer(cursorLayer)
    }

    // MARK: Configuration (any thread)

    /// `sizePixels` = backing size of the window, `scale` = backing scale factor.
    func configure(sizePixels: CGSize, scale: CGFloat, contentPoints: CGSize, topInsetPoints: CGFloat, localCursor: Bool) {
        pointer.withLockUnchecked {
            $0.boundsPoints = CGSize(width: sizePixels.width / scale, height: sizePixels.height / scale)
            $0.contentPoints = contentPoints
            $0.topInsetPoints = topInsetPoints
            $0.enabled = localCursor
            // `visible` is kept: clear() already hid the pointer when the last window went away, and
            // the sender's first position may have arrived before this (picture-in-picture: the
            // position comes on the control queue, the window opens a moment later on main).
            $0.active = true
        }
        cursorQueue.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contentsScale = scale
            CATransaction.commit()
            applyPointer()
        }
        queue.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            layer.drawableSize = sizePixels
            CATransaction.commit()
            self.contentPoints = contentPoints
            self.topInsetPixels = topInsetPoints * scale
            self.active = true
            scheduleRender()
        }
    }

    /// The window changed size (picture-in-picture): new drawable size, pointer stays as it is.
    func resize(sizePixels: CGSize, scale: CGFloat) {
        pointer.withLockUnchecked {
            $0.boundsPoints = CGSize(width: sizePixels.width / scale, height: sizePixels.height / scale)
        }
        schedulePointerUpdate()
        queue.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.contentsScale = scale
            layer.drawableSize = sizePixels
            CATransaction.commit()
            scheduleRender()
        }
    }

    func clear() {
        pointer.withLockUnchecked {
            $0.active = false
            $0.visible = false
        }
        schedulePointerUpdate()
        queue.async { [self] in
            active = false
            redrawPending = false
            lumaTexture = nil
            chromaTexture = nil
            latest.withLockUnchecked { $0.pixelBuffer = nil }
        }
    }

    /// Render queue (the layer must not change while `render()` waits for a drawable).
    private func applyVsync(_ on: Bool) {
        guard layer.displaySyncEnabled != on else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.displaySyncEnabled = on
        layer.maximumDrawableCount = on ? 2 : 3
        CATransaction.commit()
    }

    // MARK: Input (any thread)

    /// A frame that arrives while a render is still waiting replaces the one before it.
    func display(_ pixelBuffer: CVPixelBuffer, captureNs: UInt64) {
        let schedule = latest.withLockUnchecked { l -> Bool in
            l.pixelBuffer = pixelBuffer
            l.captureNs = captureNs
            return Self.markScheduled(&l)
        }
        if schedule { enqueueRender() }
    }

    /// (x, y) in points of the streamed display, top-left origin.
    func updateCursor(x: CGFloat, y: CGFloat, visible: Bool) {
        let schedule = pointer.withLockUnchecked { p -> Bool in
            let changed = p.visible != visible || (visible && (p.position.x != x || p.position.y != y))
            // Stored while disabled too, so a position that arrives just before configure() counts.
            p.position = CGPoint(x: x, y: y)
            p.visible = visible
            guard p.enabled, changed, !p.updateScheduled else { return false }
            p.updateScheduled = true
            return true
        }
        if schedule { cursorQueue.async { [self] in applyPointer() } }
    }

    func setCursorImage(_ image: CGImage, sizePoints: CGSize, hotspot: CGPoint) {
        cursorQueue.async { [self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            cursorLayer.contents = image
            CATransaction.commit()
            pointer.withLockUnchecked {
                $0.hasImage = true
                $0.sizePoints = sizePoints
                $0.hotspot = hotspot
            }
            applyPointer()
        }
    }

    // MARK: Pointer (cursor queue)

    private func schedulePointerUpdate() {
        let schedule = pointer.withLockUnchecked { p -> Bool in
            guard !p.updateScheduled else { return false }
            p.updateScheduled = true
            return true
        }
        if schedule { cursorQueue.async { [self] in applyPointer() } }
    }

    /// Moves the pointer layer to the newest position (one Core Animation transaction, no rendering).
    private func applyPointer() {
        let p = pointer.withLockUnchecked { p -> Pointer in
            p.updateScheduled = false
            return p
        }
        let show = p.enabled && p.active && p.visible && p.hasImage
            && p.boundsPoints.width > 0 && p.contentPoints.width > 0 && p.contentPoints.height > 0
        var frame = cursorFrame
        if show {
            frame = Self.pointerFrame(p, flipped: layer.isGeometryFlipped)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if show { cursorLayer.frame = frame }
        cursorLayer.isHidden = !show
        CATransaction.commit()
        cursorFrame = frame
        cursorUpdates += 1
    }

    /// Same aspect-fit as the video in `render()`, in layer points.
    private static func pointerFrame(_ p: Pointer, flipped: Bool) -> CGRect {
        let size = p.boundsPoints
        let areaHeight = size.height - p.topInsetPoints
        let fit = min(size.width / p.contentPoints.width, areaHeight / p.contentPoints.height)
        let videoX = (size.width - p.contentPoints.width * fit) / 2
        let videoTop = p.topInsetPoints + (areaHeight - p.contentPoints.height * fit) / 2
        let w = p.sizePoints.width * fit, h = p.sizePoints.height * fit
        let x = videoX + (p.position.x - p.hotspot.x) * fit
        let top = videoTop + (p.position.y - p.hotspot.y) * fit
        return CGRect(x: x, y: flipped ? top : size.height - top - h, width: w, height: h)
    }

    // MARK: Rendering (render queue)

    /// Returns true if the caller has to enqueue a render (none was scheduled yet).
    private static func markScheduled(_ l: inout Latest) -> Bool {
        if l.renderScheduled { return false }
        l.renderScheduled = true
        return true
    }

    private func scheduleRender() {
        if latest.withLockUnchecked({ Self.markScheduled(&$0) }) { enqueueRender() }
    }

    private func enqueueRender() {
        queue.async { [self] in render() }
    }

    private func render() {
        let size = layer.drawableSize
        // Wait for a drawable FIRST (this is where the window server paces us), then take whatever
        // is newest at that moment. Anything arriving after `take` schedules the next render.
        let drawable = active && size.width > 0 && size.height > 0 ? layer.nextDrawable() : nil
        let snapshot = latest.withLockUnchecked { l -> Latest in
            let copy = l
            l.pixelBuffer = nil
            l.renderScheduled = false
            return copy
        }
        guard active else { return }

        var newVideoFrame = false
        if let pixelBuffer = snapshot.pixelBuffer, let cache = textureCache {
            var luma: CVMetalTexture?
            var chroma: CVMetalTexture?
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .r8Unorm,
                                                      CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
                                                      CVPixelBufferGetHeightOfPlane(pixelBuffer, 0), 0, &luma)
            CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil, .rg8Unorm,
                                                      CVPixelBufferGetWidthOfPlane(pixelBuffer, 1),
                                                      CVPixelBufferGetHeightOfPlane(pixelBuffer, 1), 1, &chroma)
            if let luma, let chroma {
                lumaTexture = luma
                chromaTexture = chroma
                newVideoFrame = true
            } else {
                textureFailures += 1
            }
        }
        // No drawable (timeout, e.g. window hidden): the newest frame is kept in the textures and
        // drawn by a retry – a static screen sends no further frame that would trigger one.
        guard let drawable, let commandBuffer = commandQueue.makeCommandBuffer() else {
            if newVideoFrame || redrawPending {
                redrawPending = true
                queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [self] in
                    if active && redrawPending { scheduleRender() }
                }
            }
            return
        }
        redrawPending = false

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = drawable.texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Aspect-fit the streamed screen below the (optional) notch inset; top-left pixel coordinates.
        let areaHeight = size.height - topInsetPixels
        let fit = min(size.width / contentPoints.width, areaHeight / contentPoints.height)
        let videoW = contentPoints.width * fit, videoH = contentPoints.height * fit
        let videoX = (size.width - videoW) / 2
        let videoY = topInsetPixels + (areaHeight - videoH) / 2

        let luma = lumaTexture.flatMap(CVMetalTextureGetTexture)
        let chroma = chromaTexture.flatMap(CVMetalTextureGetTexture)
        if let luma, let chroma {
            var rect = SIMD4(Float(videoX / size.width * 2 - 1), Float(1 - (videoY + videoH) / size.height * 2),
                             Float((videoX + videoW) / size.width * 2 - 1), Float(1 - videoY / size.height * 2))
            encoder.setRenderPipelineState(videoPipeline)
            encoder.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            encoder.setFragmentTexture(luma, index: 0)
            encoder.setFragmentTexture(chroma, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            videoDraws += 1
        }
        encoder.endEncoding()

        // Keep the CoreVideo textures alive until the GPU is done with them.
        let keepAlive = (lumaTexture, chromaTexture)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(keepAlive) {} }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        renderedFrames += 1

        if newVideoFrame { onPresented?(snapshot.captureNs) }
    }

    /// Test hook: waits until everything submitted so far has been rendered.
    func sync() -> Int { queue.sync { renderedFrames } }

    /// Test hook: (renders that drew video, frames whose textures failed).
    func syncVideo() -> (draws: Int, textureFailures: Int) { queue.sync { (videoDraws, textureFailures) } }

    /// Test hook: waits until all pointer updates so far are applied; returns (updates, last frame, flipped).
    func syncCursor() -> (updates: Int, frame: CGRect, hidden: Bool) {
        cursorQueue.sync { (cursorUpdates, cursorFrame, cursorLayer.isHidden) }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; float2 uv; };

    // rect = (left, bottom, right, top) in normalized device coordinates
    vertex VOut quad_vs(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
        float2 c = float2(vid & 1, vid >> 1);
        VOut o;
        o.position = float4(mix(rect.x, rect.z, c.x), mix(rect.y, rect.w, c.y), 0.0, 1.0);
        o.uv = float2(c.x, 1.0 - c.y);
        return o;
    }

    // NV12, BT.709 video range → RGB (values stay sRGB-encoded, like the captured screen)
    fragment float4 nv12_fs(VOut in [[stage_in]],
                            texture2d<float> luma [[texture(0)]],
                            texture2d<float> chroma [[texture(1)]]) {
        constexpr sampler s(filter::linear, address::clamp_to_edge);
        float y = (luma.sample(s, in.uv).r - 16.0 / 255.0) * (255.0 / 219.0);
        float2 c = (chroma.sample(s, in.uv).rg - 128.0 / 255.0) * (255.0 / 224.0);
        float3 rgb = float3(y + 1.5748 * c.y,
                            y - 0.1873 * c.x - 0.4681 * c.y,
                            y + 1.8556 * c.x);
        return float4(saturate(rgb), 1.0);
    }
    """
}
