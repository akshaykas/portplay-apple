import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit

/// Shows the live capture feed, letterboxed to keep the console's aspect ratio.
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: PreviewUIView, context: Context) {
        view.device = device
    }
}

final class PreviewUIView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // layerClass guarantees this cast.
        layer as! AVCaptureVideoPreviewLayer
    }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var angle: CGFloat = 0

    /// Keeps the picture upright as the iPad rotates.
    var device: AVCaptureDevice? {
        didSet {
            guard device != oldValue else { return }
            rotationObservation = nil
            rotationCoordinator = nil
            guard let device else { return }

            let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
            rotationCoordinator = coordinator
            rotationObservation = coordinator.observe(
                \.videoRotationAngleForHorizonLevelPreview,
                options: [.initial, .new]
            ) { [weak self] coordinator, _ in
                let newAngle = coordinator.videoRotationAngleForHorizonLevelPreview
                DispatchQueue.main.async { self?.applyRotation(newAngle) }
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // The connection appears only after the dongle is attached, so reapply here.
        applyRotation(angle)
    }

    private func applyRotation(_ newAngle: CGFloat) {
        angle = newAngle
        guard let connection = previewLayer.connection,
              connection.isVideoRotationAngleSupported(newAngle) else { return }
        connection.videoRotationAngle = newAngle
    }
}

#else
import AppKit

/// Shows the live capture feed, letterboxed to keep the console's aspect ratio.
struct PreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        return view
    }

    func updateNSView(_ view: PreviewNSView, context: Context) {
        view.needsLayout = true
    }
}

final class PreviewNSView: NSView {
    let previewLayer = AVCaptureVideoPreviewLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()

        // Never mirror a console picture, even if macOS treats the dongle like a webcam.
        if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }
}
#endif
