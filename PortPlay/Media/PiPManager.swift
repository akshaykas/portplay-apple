import AVFoundation
import AVKit

/// Picture in picture. While a dongle is connected, every frame also goes to the
/// floating window's layer, so picture in picture is ready the moment it's asked for.
/// That layer sits underneath the main picture, so it adds no visible work.
final class PiPManager: NSObject, AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate, @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()

    /// Called on the main thread when the floating window opens or closes.
    var onActiveChange: ((Bool) -> Void)?
    /// Called on the main thread when picture in picture can't start.
    var onFailure: (() -> Void)?

    private weak var hub: FrameHub?
    private var controller: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var pendingStart = false

    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var announcedFrames = false

    init(hub: FrameHub) {
        self.hub = hub
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Frames carry host clock timestamps, so play them on the host clock.
        // Without a running timebase the floating window never becomes available.
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase)
        if let timebase {
            CMTimebaseSetTime(timebase, time: CMClockGetTime(CMClockGetHostTimeClock()))
            CMTimebaseSetRate(timebase, rate: 1)
            displayLayer.controlTimebase = timebase
        }

        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer, playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.requiresLinearPlayback = true
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        self.controller = controller

        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.startIfPending() }
        }
    }

    var isSupported: Bool { controller != nil }
    var isActive: Bool { controller?.isPictureInPictureActive ?? false }

    // MARK: Control, from the main thread

    /// Starts sending frames to the floating window's layer. Called when a dongle connects.
    func beginFeeding() {
        hub?.setPiP(self)
    }

    /// Stops sending frames and closes the floating window. Called when the dongle goes away.
    func stop() {
        pendingStart = false
        if controller?.isPictureInPictureActive == true {
            controller?.stopPictureInPicture()
        }
        hub?.setPiP(nil)
        lock.withLock { announcedFrames = false }
        displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    func toggle() {
        guard let controller else {
            onFailure?()
            return
        }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
            return
        }

        #if os(iOS)
        // Picture in picture needs an active playback audio session on iPad
        let audioSession = AVAudioSession.sharedInstance()
        if audioSession.category != .playAndRecord {
            try? audioSession.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        }
        try? audioSession.setActive(true)
        #endif

        if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
            return
        }

        // Not ready yet, usually right after connecting. Start as soon as it is.
        pendingStart = true
        controller.invalidatePlaybackState()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.pendingStart else { return }
            self.pendingStart = false
            self.onFailure?()
        }
    }

    private func startIfPending() {
        guard pendingStart, let controller, controller.isPictureInPicturePossible else { return }
        pendingStart = false
        controller.startPictureInPicture()
    }

    // MARK: Frames, from the capture queue

    func enqueue(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        let format: CMVideoFormatDescription? = lock.withLock {
            if let existing = formatDescription, CMVideoFormatDescriptionMatchesImageBuffer(existing, imageBuffer: pixelBuffer) {
                return existing
            }
            var created: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &created)
            formatDescription = created
            return created
        }
        guard let format else { return }

        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard let sample else { return }

        // Live video: show each frame as soon as it arrives
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                dictionary,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }

        let renderer = displayLayer.sampleBufferRenderer
        if renderer.status == .failed {
            renderer.flush()
        }
        renderer.enqueue(sample)

        // The first frame makes picture in picture possible, so let the controller know
        let firstFrame = lock.withLock { () -> Bool in
            defer { announcedFrames = true }
            return !announcedFrames
        }
        if firstFrame {
            DispatchQueue.main.async { [weak self] in
                self?.controller?.invalidatePlaybackState()
            }
        }
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async { self.onActiveChange?(true) }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        DispatchQueue.main.async {
            self.onActiveChange?(false)
        }
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
        DispatchQueue.main.async {
            self.pendingStart = false
            self.onFailure?()
        }
    }

    // MARK: AVPictureInPictureSampleBufferPlaybackDelegate

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {}

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live content with no start or end
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        skipByInterval skipInterval: CMTime,
        completion completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
