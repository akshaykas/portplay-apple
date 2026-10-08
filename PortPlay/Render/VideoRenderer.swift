import CoreVideo
import Metal
import QuartzCore

/// Draws each frame with Metal the moment it arrives, applying the scaling
/// mode and retro filter, and measures how long frames take to reach the screen.
final class VideoRenderer: @unchecked Sendable {
    let layer = CAMetalLayer()

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
        layer.maximumDrawableCount = 3
        layer.allowsNextDrawableTimeout = true
    }

    // MARK: Settings, from the main thread

    func configure(scaling: ScaleMode, filter: RetroFilter, lowLatency: Bool) {
        lock.withLock {
            self.scaling = scaling
            self.filter = lowLatency ? .off : filter
        }
        #if os(macOS)
        // Draw as soon as a frame is ready instead of waiting for the next screen refresh
        layer.displaySyncEnabled = !lowLatency
        #endif
        redraw()
    }

    func updateSize(_ size: CGSize, pixelsPerPoint scale: CGFloat) {
        guard size.width > 0, size.height > 0 else { return }
        lock.withLock { pixelsPerPoint = scale }
        layer.contentsScale = scale
        layer.drawableSize = CGSize(width: size.width * scale, height: size.height * scale)
        redraw()
    }

    // MARK: Drawing

    /// Called on the capture queue for every new frame.
    func render(_ pixelBuffer: CVPixelBuffer, captureTime: CFTimeInterval) {
        lock.withLock { lastBuffer = pixelBuffer }
        draw(pixelBuffer, captureTime: captureTime)
    }

    /// Draws the last frame again, after a resize or a settings change.
    func redraw() {
        redrawQueue.async { [weak self] in
            guard let self else { return }
            self.draw(self.lock.withLock { self.lastBuffer }, captureTime: nil)
        }
    }

    /// Forgets the last frame and paints the screen black.
    func clear() {
        lock.withLock {
            lastBuffer = nil
            latencies.removeAll()
            currentScaleText = ""
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

            if let captureTime {
                drawable.addPresentedHandler { [weak self] presented in
                    let shown = presented.presentedTime
                    guard shown > 0 else { return }
                    self?.recordLatency(shown - captureTime)
                }
            }
            // Keep the texture alive until the GPU is done with it
            commandBuffer.addCompletedHandler { _ in _ = cvTexture }
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
