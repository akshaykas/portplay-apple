import AVFoundation
import SwiftUI

// Hosts the layers that show the game, bottom to top:
// 1. Picture in picture's display layer, which only has content while it's open
// 2. The camera layer, which shows the clean picture with the least delay
// 3. The Metal layer, used for retro filters and pixel perfect scaling
//
// Clicks and touches pass through to SwiftUI.

/// Shared layer setup for both platforms.
@MainActor
private final class SurfaceLayers {
    let renderer: VideoRenderer
    let pip: PiPManager
    let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession, renderer: VideoRenderer, pip: PiPManager) {
        self.renderer = renderer
        self.pip = pip
        preview = AVCaptureVideoPreviewLayer(session: session)
        preview.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
    }

    func install(in host: CALayer) {
        host.addSublayer(pip.displayLayer)
        host.addSublayer(preview)
        host.addSublayer(renderer.layer)
    }

    func layout(bounds: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        pip.displayLayer.frame = bounds
        renderer.layer.frame = bounds

        let direct = renderer.path == .direct
        preview.isHidden = !direct
        renderer.layer.isHidden = direct

        switch renderer.scalingMode {
        case .stretch:
            preview.videoGravity = .resize
            preview.frame = bounds
        case .aspect43:
            // Squeeze the picture into a 4:3 box, like the Windows version
            let width = min(bounds.width, bounds.height * 4 / 3).rounded(.down)
            let height = (width * 3 / 4).rounded(.down)
            preview.videoGravity = .resize
            preview.frame = CGRect(
                x: ((bounds.width - width) / 2).rounded(.down),
                y: ((bounds.height - height) / 2).rounded(.down),
                width: width,
                height: height
            )
        case .fit, .integer:
            preview.videoGravity = .resizeAspect
            preview.frame = bounds
        }

        // Console pictures are never rotated or mirrored
        if let connection = preview.connection {
            if connection.isVideoRotationAngleSupported(0) {
                connection.videoRotationAngle = 0
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
        }

        CATransaction.commit()
    }
}

#if os(iOS)
import UIKit

struct VideoSurface: UIViewRepresentable {
    let session: AVCaptureSession
    let renderer: VideoRenderer
    let pip: PiPManager

    func makeUIView(context: Context) -> VideoSurfaceView {
        VideoSurfaceView(session: session, renderer: renderer, pip: pip)
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {}
}

final class VideoSurfaceView: UIView {
    private let layers: SurfaceLayers

    init(session: AVCaptureSession, renderer: VideoRenderer, pip: PiPManager) {
        layers = SurfaceLayers(session: session, renderer: renderer, pip: pip)
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layers.install(in: layer)
        renderer.onLayoutChange = { [weak self] in
            self?.setNeedsLayout()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layers.layout(bounds: bounds)
        layers.renderer.updateSize(
            bounds.size,
            pixelsPerPoint: window?.screen.scale ?? traitCollection.displayScale,
            refreshRate: window?.screen.maximumFramesPerSecond ?? 60
        )
    }
}

#else
import AppKit

struct VideoSurface: NSViewRepresentable {
    let session: AVCaptureSession
    let renderer: VideoRenderer
    let pip: PiPManager

    func makeNSView(context: Context) -> VideoSurfaceView {
        VideoSurfaceView(session: session, renderer: renderer, pip: pip)
    }

    func updateNSView(_ view: VideoSurfaceView, context: Context) {}
}

final class VideoSurfaceView: NSView {
    private let layers: SurfaceLayers

    init(session: AVCaptureSession, renderer: VideoRenderer, pip: PiPManager) {
        layers = SurfaceLayers(session: session, renderer: renderer, pip: pip)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        if let layer {
            layers.install(in: layer)
        }
        renderer.onLayoutChange = { [weak self] in
            self?.resizeLayers()
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    /// Let SwiftUI see every click.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        resizeLayers()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        resizeLayers()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        resizeLayers()
    }

    private func resizeLayers() {
        layers.layout(bounds: bounds)
        layers.renderer.updateSize(
            bounds.size,
            pixelsPerPoint: window?.backingScaleFactor ?? 2,
            refreshRate: window?.screen?.maximumFramesPerSecond ?? 60
        )
    }
}
#endif
