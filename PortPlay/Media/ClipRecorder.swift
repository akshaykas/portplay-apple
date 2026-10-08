import AVFoundation
import QuartzCore

/// A simple start and stop recording to an MP4 file: the clean picture plus game audio,
/// and on Mac any microphone the person picked.
final class ClipRecorder: @unchecked Sendable {
    let url: URL

    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let lock = NSLock()
    private var started = false
    private var finished = false
    private var startTime = CMTime.invalid
    private let createdAt = CACurrentMediaTime()

    init(url: URL, mode: RunningMode, audioFormat: AVAudioFormat?) throws {
        self.url = url
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(mode.width),
            AVVideoHeightKey: Int(mode.height),
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: MediaBuffers.bitrate(width: mode.width, height: mode.height, fps: mode.fps, forReplay: false),
                AVVideoMaxKeyFrameIntervalDurationKey: 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoExpectedSourceFrameRateKey: Int(mode.fps.rounded()),
            ],
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: nil)
        writer.add(videoInput)

        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: MediaBuffers.aacSettings(for: audioFormat))
            input.expectsMediaDataInRealTime = true
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

        guard writer.startWriting() else {
            throw writer.error ?? CocoaError(.fileWriteUnknown)
        }
    }

    var elapsed: TimeInterval {
        CACurrentMediaTime() - createdAt
    }

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard !finished, writer.status == .writing else { return }
        if !started {
            writer.startSession(atSourceTime: time)
            startTime = time
            started = true
        }
        if videoInput.isReadyForMoreMediaData {
            adaptor.append(pixelBuffer, withPresentationTime: time)
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard let audioInput, started, !finished, writer.status == .writing else { return }
        guard CMTimeCompare(time, startTime) >= 0, audioInput.isReadyForMoreMediaData else { return }
        if let sample = MediaBuffers.audioSampleBuffer(buffer, at: time) {
            audioInput.append(sample)
        }
    }

    /// Finishes the file. Hands back nil if nothing was recorded.
    func finish(completion: @escaping (URL?) -> Void) {
        lock.lock()
        let wasStarted = started
        finished = true
        lock.unlock()

        guard wasStarted, writer.status == .writing else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { completion(nil) }
            return
        }

        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        let url = self.url
        let writer = self.writer
        writer.finishWriting {
            let ok = writer.status == .completed
            DispatchQueue.main.async { completion(ok ? url : nil) }
        }
    }
}
