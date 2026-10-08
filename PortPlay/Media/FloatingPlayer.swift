#if os(macOS)
import AppKit
import AVFoundation

/// Picture in picture on Mac: a small window that floats above everything else,
/// like the browser's picture in picture window in the Windows version.
/// It shows the dongle through its own camera layer, so it adds no delay.
@MainActor
final class FloatingPlayer: NSObject, NSWindowDelegate {
    /// Called when the window closes, however it was closed.
    var onClose: (() -> Void)?
    /// Called when the window is double clicked, to go back to the main window.
    var onDoubleClick: (() -> Void)?

    private var panel: NSPanel?

    var isOpen: Bool { panel != nil }

    func show(session: AVCaptureSession, aspect: CGSize) {
        if let panel {
            panel.orderFrontRegardless()
            return
        }

        let ratio = aspect.width > 0 && aspect.height > 0 ? aspect : CGSize(width: 16, height: 9)
        let width: CGFloat = 480
        let height = (width * ratio.height / ratio.width).rounded()
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let frame = NSRect(
            x: visible.maxX - width - 24,
            y: visible.minY + 24,
            width: width,
            height: height
        )

        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "PortPlay"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .black
        panel.contentAspectRatio = ratio
        panel.minSize = NSSize(width: 240, height: 240 * ratio.height / ratio.width)
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let view = FloatingVideoView(session: session)
        view.onDoubleClick = { [weak self] in self?.onDoubleClick?() }
        panel.contentView = view

        self.panel = panel
        panel.orderFrontRegardless()
    }

    func close() {
        panel?.close()
    }

    func windowWillClose(_ notification: Notification) {
        panel?.delegate = nil
        panel = nil
        onClose?()
    }
}

/// The floating window's picture. Drag anywhere to move it, double click to go back.
private final class FloatingVideoView: NSView {
    var onDoubleClick: (() -> Void)?
    private let preview: AVCaptureVideoPreviewLayer

    init(session: AVCaptureSession) {
        preview = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        preview.videoGravity = .resizeAspect
        preview.backgroundColor = NSColor.black.cgColor
        layer?.addSublayer(preview)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        preview.frame = bounds
        CATransaction.commit()
        if let connection = preview.connection, connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            onDoubleClick?()
        } else {
            window?.performDrag(with: event)
        }
    }
}
#endif
