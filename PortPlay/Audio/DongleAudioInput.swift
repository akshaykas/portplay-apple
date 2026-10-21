#if os(macOS)
import AVFoundation
import QuartzCore

/// Reads the dongle's sound on a Mac through an AVFoundation capture session,
/// the same way the picture is read.
///
/// The older approach pointed an AVAudioEngine input at the dongle with
/// Core Audio. That only worked for the Mac's default input, so a USB dongle
/// stayed silent. A capture session opens any audio device by its ID and
/// converts whatever the dongle sends into the format PortPlay plays.
final class DongleAudioInput: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    /// What PortPlay plays and records: float samples, one buffer per channel, mono or stereo.
    let format: AVAudioFormat

    /// Called on the capture queue with converted sound and when it arrived, in host seconds.
    var onAudio: ((AVAudioPCMBuffer, Double) -> Void)?

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "PortPlay.dongleAudio", qos: .userInteractive)

    // Only touched on the capture queue
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    private let lock = NSLock()
    private var lastBufferSeconds = 0.0

    /// How much sound arrives at once, which is part of the delay.
    var bufferDuration: Double { lock.withLock { lastBufferSeconds } }

    init(device: AVCaptureDevice) throws {
        let description = CMAudioFormatDescriptionGetStreamBasicDescription(device.activeFormat.formatDescription)?.pointee
        let deviceRate = description?.mSampleRate ?? 0
        let rate = deviceRate > 0 ? deviceRate : 48_000
        let channels = AVAudioChannelCount(min(max(Int(description?.mChannelsPerFrame ?? 2), 1), 2))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else {
            throw AudioError.noSignal
        }
        self.format = format
        super.init()

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AudioError.couldNotSelect
        }

        session.beginConfiguration()
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw AudioError.couldNotSelect
        }
        session.addInput(input)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw AudioError.couldNotSelect
        }
        session.addOutput(output)
        session.commitConfiguration()
        output.setSampleBufferDelegate(self, queue: queue)
    }

    func start() {
        let session = self.session
        queue.async { session.startRunning() }
    }

    func stop() {
        output.setSampleBufferDelegate(nil, queue: nil)
        let session = self.session
        queue.async { session.stopRunning() }
    }

    // MARK: Sound from the dongle

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let onAudio,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let converted = convert(sampleBuffer, description: description),
              converted.frameLength > 0
        else { return }

        lock.withLock { lastBufferSeconds = Double(converted.frameLength) / format.sampleRate }
        onAudio(converted, hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    /// Copies the dongle's samples out and converts them to `format`.
    private func convert(_ sampleBuffer: CMSampleBuffer, description: CMFormatDescription) -> AVAudioPCMBuffer? {
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frames > 0 else { return nil }

        let sourceFormat = AVAudioFormat(cmAudioFormatDescription: description)
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(frames)) else { return nil }
        source.frameLength = AVAudioFrameCount(frames)
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frames),
            into: source.mutableAudioBufferList
        ) == noErr else { return nil }

        // Already in the right shape
        if sourceFormat == format { return source }

        if converterSource != sourceFormat {
            guard let newConverter = AVAudioConverter(from: sourceFormat, to: format) else { return nil }
            if sourceFormat.channelCount == 1, format.channelCount == 2 {
                newConverter.channelMap = [0, 0]
            } else if sourceFormat.channelCount > format.channelCount {
                newConverter.downmix = true
            }
            converter = newConverter
            converterSource = sourceFormat
        }
        guard let converter else { return nil }

        let ratio = format.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount(Double(frames) * ratio + 64)
        guard let target = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        _ = converter.convert(to: target, error: &error) { _, status in
            if fed {
                status.pointee = .noDataNow
                return nil
            }
            fed = true
            status.pointee = .haveData
            return source
        }
        return error == nil ? target : nil
    }

    /// When the sound reached the Mac, on the same clock as the picture.
    private func hostSeconds(_ pts: CMTime) -> Double {
        let host = CMClockGetHostTimeClock()
        let seconds = CMSyncConvertTime(pts, from: session.synchronizationClock ?? host, to: host).seconds
        let now = CACurrentMediaTime()
        return seconds.isFinite && abs(now - seconds) < 2 ? seconds : now
    }
}
#endif
