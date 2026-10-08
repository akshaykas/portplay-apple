import CoreVideo
import Metal
import QuartzCore

/// Decides how each frame reaches the screen, and measures how long that takes.
///
/// Like the Windows version, the clean picture goes straight to the screen through
/// the system's own camera layer, which is the fastest path there is. Metal only
/// draws the picture when it has to: for the retro filters and pixel perfect scaling.
final class VideoRenderer: @unchecked Sendable {
    enum Path: Equatable {
        /// AVCaptureVideoPreviewLayer shows the picture
        case direct
        /// This renderer draws every frame
        case metal
    }

    let layer = CAMetalLayer()

    /// Called on the main thread when the path or scaling changes, so the view can lay out its layers.
    var onLayoutChange: (() -> Void)?

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let linearSampler: MTLSamplerState
    private let nearestSampler: MTLSamplerState
    private var textureCache: CVMetalTextureCache?
    private let redrawQueue = DispatchQueue(label: "PortPlay.redraw", qos: .userInteractive)

    private let lock = NSLock()
    private var scaling = ScaleMode.fit
    private var filter = RetroFilter.off
    private var pixelsPerPoint: CGFloat = 1
    private var lastBuffer: CVPixelBuffer?
    private var latencies: [Double] = []
    private var currentScaleText = ""
    private var syncedToDisplay = true
    private var displayInterval = 1.0 / 60
    private var currentPath = Path.direct

    /// Matches FilterUniforms in ShaderSource.
    private struct Uniforms {
        var srcSize: SIMD2<Float>
        var lines: Float
        var mode: Int32
    }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: ShaderSource.metal, options: nil),
              let vertex = library.makeFunction(name: "portplay_vertex"),
              let fragment = library.makeFunction(name: "portplay_fragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        func sampler(_ filter: MTLSamplerMinMagFilter) -> MTLSamplerState? {
            let d = MTLSamplerDescriptor()
            d.minFilter = filter
            d.magFilter = filter
            d.sAddressMode = .clampToEdge
            d.tAddressMode = .clampToEdge
            return device.makeSamplerState(descriptor: d)
        }
        guard let linear = sampler(.linear), let nearest = sampler(.nearest) else { return nil }

        self.device = device
        self.queue = queue
        self.pipeline = pipeline
        self.linearSampler = linear
        self.nearestSampler = nearest
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        layer.device = device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        // Two drawables keeps at most one frame waiting for the screen
        layer.maximumDrawableCount = 2
        layer.allowsNextDrawableTimeout = true
        layer.isHidden = true
    }

    var path: Path {
        lock.withLock { currentPath }
    }

    var scalingMode: ScaleMode {
        lock.withLock { scaling }
    }

    // MARK: Settings, from the main thread

    func configure(scaling: ScaleMode, filter: RetroFilter, lowLatency: Bool) {
        let activeFilter = lowLatency ? RetroFilter.off : filter
        let newPath: Path = activeFilter == .off && scaling != .integer ? .direct : .metal
        lock.withLock {
            self.scaling = scaling
            self.filter = activeFilter
            self.currentPath = newPath
            #if os(macOS)
            self.syncedToDisplay = !lowLatency
            #endif
            if newPath == .direct {
                currentScaleText = Self.directScaleText(scaling)
            }
        }
        #if os(macOS)
        // Draw as soon as a frame is ready instead of waiting for the next screen refresh
        layer.displaySyncEnabled = !lowLatency
        #endif
        onLayoutChange?()
        if newPath == .metal {
            redraw()
        }
    }

    private static func directScaleText(_ mode: ScaleMode) -> String {
        switch mode {
        case .fit: return "Fit"
        case .stretch: return "Stretch"
        case .aspect43: return "4:3"
        case .integer: return "Pixel"
        }
    }

    func updateSize(_ size: CGSize, pixelsPerPoint scale: CGFloat, refreshRate: Int) {
        guard size.width > 0, size.height > 0 else { return }
        lock.withLock {
            pixelsPerPoint = scale
            displayInterval = 1 / Double(max(refreshRate, 30))
        }
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        redraw()
    }

    // MARK: Drawing

    /// Called on the capture queue for every new frame.
    func render(_ pixelBuffer: CVPixelBuffer, captureTime: CFTimeInterval) {
        let (path, refreshWait) = lock.withLock { () -> (Path, Double) in
            lastBuffer = pixelBuffer
            return (currentPath, displayInterval)
        }
        if path == .direct {
            // The camera layer shows this frame at the next screen refresh
            recordLatency(CACurrentMediaTime() - captureTime + refreshWait)
            return
        }
        draw(pixelBuffer, captureTime: captureTime)
    }

    /// Draws the last frame again, after a resize or a settings change.
    func redraw() {
        redrawQueue.async { [weak self] in
            guard let self else { return }
            let (path, buffer) = self.lock.withLock { (self.currentPath, self.lastBuffer) }
            guard path == .metal else { return }
            self.draw(buffer, captureTime: nil)
        }
    }

    /// Forgets the last frame and paints the screen black.
    func clear() {
        lock.withLock {
            lastBuffer = nil
            latencies.removeAll()
            if currentPath == .metal { currentScaleText = "" }
        }
        redraw()
    }

    private func draw(_ pixelBuffer: CVPixelBuffer?, captureTime: CFTimeInterval?) {
        autoreleasepool {
            guard let drawable = layer.nextDrawable(),
                  let commandBuffer = queue.makeCommandBuffer()
            else { return }

            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = drawable.texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

            let (scaling, filter, scale) = lock.withLock { (self.scaling, self.filter, self.pixelsPerPoint) }
            var cvTexture: CVMetalTexture?

            if let pixelBuffer, let cache = textureCache {
                let width = CVPixelBufferGetWidth(pixelBuffer)
                let height = CVPixelBufferGetHeight(pixelBuffer)
                CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture
                )
                if let cvTexture, let texture = CVMetalTextureGetTexture(cvTexture) {
                    let placement = Self.place(
                        mode: scaling,
                        target: CGSize(width: drawable.texture.width, height: drawable.texture.height),
                        source: CGSize(width: width, height: height),
                        pixelsPerPoint: scale
                    )
                    lock.withLock { currentScaleText = placement.text }

                    encoder.setViewport(MTLViewport(
                        originX: placement.rect.minX, originY: placement.rect.minY,
                        width: placement.rect.width, height: placement.rect.height,
                        znear: 0, zfar: 1
                    ))
                    encoder.setRenderPipelineState(pipeline)
                    encoder.setFragmentTexture(texture, index: 0)
                    encoder.setFragmentSamplerState(scaling == .integer ? nearestSampler : linearSampler, index: 0)
                    var uniforms = Uniforms(
                        srcSize: SIMD2(Float(width), Float(height)),
                        lines: Self.scanlineCount(forHeight: height),
                        mode: filter.shaderMode
                    )
                    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
                    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
                }
            }
            encoder.endEncoding()

            // When the GPU finishes, the frame is ready. It reaches the screen at the
            // next refresh, or right away on Mac in low latency mode.
            let refreshWait = lock.withLock { syncedToDisplay ? displayInterval : 0 }
            commandBuffer.addCompletedHandler { [weak self] _ in
                // Keep the texture alive until the GPU is done with it
                _ = cvTexture
                if let captureTime {
                    self?.recordLatency(CACurrentMediaTime() - captureTime + refreshWait)
                }
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    // MARK: Stats

    private func recordLatency(_ seconds: Double) {
        let ms = seconds * 1000
        guard ms > 0, ms < 1000 else { return }
        lock.withLock {
            latencies.append(ms)
            if latencies.count > 60 { latencies.removeFirst() }
        }
    }

    /// Average time from a frame reaching this device to it showing on screen.
    var averageLatency: Double? {
        lock.withLock { latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count) }
    }

    var scaleText: String {
        lock.withLock { currentScaleText }
    }

    // MARK: Layout

    /// Retro games are usually 240 lines, doubled or more by the console or upscaler.
    private static func scanlineCount(forHeight h: Int) -> Float {
        if h <= 288 { return Float(h) }
        if h <= 576 { return Float(h) / 2 }
        return 240
    }

    /// Where the picture goes inside the drawable, in physical pixels. Same rules as the Windows version.
    private static func place(mode: ScaleMode, target: CGSize, source: CGSize, pixelsPerPoint: CGFloat) -> (rect: CGRect, text: String) {
        let W = target.width
        let H = target.height
        let w0 = source.width
        let h0 = source.height

        func centered(_ w: CGFloat, _ h: CGFloat) -> CGRect {
            CGRect(x: ((W - w) / 2).rounded(.down), y: ((H - h) / 2).rounded(.down), width: w.rounded(), height: h.rounded())
        }

        switch mode {
        case .stretch:
            return (CGRect(x: 0, y: 0, width: W, height: H), "Stretch")

        case .aspect43:
            // Squeeze the picture into a 4:3 box. Fixes retro consoles that come out stretched to 16:9.
            let w = min(W, H * 4 / 3).rounded(.down)
            return (centered(w, (w * 3 / 4).rounded(.down)), "4:3")

        case .integer:
            // Each source pixel becomes an exact block of physical pixels
            let k = (min(W / w0, H / h0)).rounded(.down)
            if k >= 1 {
                return (centered(w0 * k, h0 * k), "\(Int(k))x pixel perfect")
            }
            let s = min(W / w0, H / h0)
            return (centered(w0 * s, h0 * s), "Fit (window smaller than signal)")

        case .fit:
            let s = min(W / w0, H / h0)
            return (centered(w0 * s, h0 * s), "Fit")
        }
    }
}
