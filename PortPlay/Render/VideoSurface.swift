import AVFoundation
import SwiftUI

// Hosts the Metal layer that shows the game, with picture in picture's
// display layer tucked underneath it. Touches and clicks pass straight
// through to SwiftUI, which handles taps, double clicks and hovering.

#if os(iOS)
import UIKit

struct VideoSurface: UIViewRepresentable {
    let renderer: VideoRenderer
    let pip: PiPManager

    func makeUIView(context: Context) -> VideoSurfaceView {
        VideoSurfaceView(renderer: renderer, pip: pip)
    }

    func updateUIView(_ view: VideoSurfaceView, context: Context) {}
}

final class VideoSurfaceView: UIView {
    private let renderer: VideoRenderer
    private let pip: PiPManager

    init(renderer: VideoRenderer, pip: PiPManager) {
        self.renderer = renderer
        self.pip = pip
        super.init(frame: .zero)
        backgroundColor = .black
        isUserInteractionEnabled = false
        layer.addSublayer(pip.displayLayer)
        layer.addSublayer(renderer.layer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pip.displayLayer.frame = bounds
        renderer.layer.frame = bounds
        CATransaction.commit()
        renderer.updateSize(bounds.size, pixelsPerPoint: window?.screen.scale ?? traitCollection.displayScale)
    }
}

#else
import AppKit

struct VideoSurface: NSViewRepresentable {
    let renderer: VideoRenderer
    let pip: PiPManager

    func makeNSView(context: Context) -> VideoSurfaceView {
        VideoSurfaceView(renderer: renderer, pip: pip)
    }

    func updateNSView(_ view: VideoSurfaceView, context: Context) {}
}

final class VideoSurfaceView: NSView {
    private let renderer: VideoRenderer
    private let pip: PiPManager

    init(renderer: VideoRenderer, pip: PiPManager) {
        self.renderer = renderer
        self.pip = pip
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(pip.displayLayer)
        layer?.addSublayer(renderer.layer)
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
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pip.displayLayer.frame = bounds
        renderer.layer.frame = bounds
        CATransaction.commit()
        renderer.updateSize(bounds.size, pixelsPerPoint: window?.backingScaleFactor ?? 2)
    }
}
#endif
