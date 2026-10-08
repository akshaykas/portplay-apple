import AVFoundation
import VideoToolbox

/// Instant replay. Frames are encoded as they arrive, with a keyframe every
/// second, and kept in memory along with the game audio. Saving writes out the
/// last 30 seconds without encoding the video again, so it only takes a moment.
final class ReplayBuffer: @unchecked Sendable {
    static let seconds: Double = 30

    private var session: VTCompressionSession?
    private let lock = NSLock()
    private var video: [CMSampleBuffer] = []
    private var audio: [(buffer: AVAudioPCMBuffer, time: CMTime)] = []
    private var running = true
    private let writeQueue = DispatchQueue(label: "PortPlay.replay-save", qos: .userInitiated)

    init?(mode: RunningMode) {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: mode.width,
            height: mode.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created
        )
        guard status == noErr, let created else { return nil }

        let bitrate = MediaBuffers.bitrate(width: mode.width, height: mode.height, fps: mode.fps, forReplay: true)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_High_AutoLevel)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 1 as CFNumber)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(created, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: mode.fps as CFNumber)
        VTCompressionSessionPrepareToEncodeFrames(created)
        session = created
    }

    deinit {
        stop()
    }

    func stop() {
        lock.lock()
        running = false
        let session = self.session
        self.session = nil
        video.removeAll()
        audio.removeAll()
        lock.unlock()
        if let session {
            VTCompressionSessionInvalidate(session)
        }
    }

    // MARK: Filling

    func appendVideo(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let session = lock.withLock({ running ? self.session : nil }) else { return }
        VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: time,
            duration: .invalid,
            frameProperties: nil,
            infoFlagsOut: nil
        ) { [weak self] status, _, sample in
            guard status == noErr, let sample else { return }
            self?.store(sample)
        }
    }

    func appendAudio(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        guard let copy = MediaBuffers.copy(buffer) else { return }
        lock.withLock {
            guard running else { return }
            audio.append((copy, time))
        }
    }

    private func store(_ sample: CMSampleBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard running else { return }
        video.append(sample)
        trim()
    }

    /// Drops whole keyframe groups from the front while more than 30 seconds remain.
    private func trim() {
        guard let newest = video.last?.presentationTimeStamp.seconds else { return }
        while let next = video.dropFirst().firstIndex(where: Self.isKeyframe),
              newest - video[next].presentationTimeStamp.seconds >= Self.seconds + 0.5 {
            video.removeFirst(next)
        }
        if let oldest = video.first?.presentationTimeStamp.seconds {
            audio.removeAll { $0.time.seconds < oldest - 1 }
        }
    }

    private static func isKeyframe(_ sample: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[String: Any]],
              let first = attachments.first
        else { return true }
        return (first[kCMSampleAttachmentKey_NotSync as String] as? Bool) != true
    }

    // MARK: Saving

    /// Seconds of footage a save would contain right now.
    var available: Double {
        lock.withLock {
            guard let first = video.first, let last = video.last else { return 0 }
            return last.presentationTimeStamp.seconds - first.presentationTimeStamp.seconds
        }
    }

    /// Writes the last 30 seconds to `url`. Hands back how many seconds were saved, or nil.
    func save(to url: URL, audioFormat: AVAudioFormat?, completion: @escaping (Int?) -> Void) {
        let (videoSamples, audioBuffers): ([CMSampleBuffer], [(buffer: AVAudioPCMBuffer, time: CMTime)]) = lock.withLock {
            guard let newest = video.last?.presentationTimeStamp.seconds else { return ([], []) }
            // Start on the last keyframe that still gives a full 30 seconds
            let start = video.lastIndex { Self.isKeyframe($0) && newest - $0.presentationTimeStamp.seconds >= Self.seconds } ?? 0
            return (Array(video[start...]), audio)
        }

        guard let first = videoSamples.first, let last = videoSamples.last,
              let format = CMSampleBufferGetFormatDescription(first)
        else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        writeQueue.async {
            do {
                try? FileManager.default.removeItem(at: url)
                let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)

                let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: format)
                videoInput.expectsMediaDataInRealTime = false
                writer.add(videoInput)

                var audioInput: AVAssetWriterInput?
                if let audioFormat, !audioBuffers.isEmpty {
                    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: MediaBuffers.aacSettings(for: audioFormat))
                    input.expectsMediaDataInRealTime = false
                    if writer.canAdd(input) {
                        writer.add(input)
                        audioInput = input
                    }
                }

                guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                let startTime = first.presentationTimeStamp
                writer.startSession(atSourceTime: startTime)

                func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
                    var waited = 0
                    while !input.isReadyForMoreMediaData {
                        if writer.status != .writing || waited > 5000 { return false }
                        usleep(1000)
                        waited += 1
                    }
                    return true
                }

                for sample in videoSamples {
                    guard waitUntilReady(videoInput) else { break }
                    videoInput.append(sample)
                }
                videoInput.markAsFinished()

                if let audioInput {
                    for item in audioBuffers where CMTimeCompare(item.time, startTime) >= 0 {
                        guard let sample = MediaBuffers.audioSampleBuffer(item.buffer, at: item.time) else { continue }
                        guard waitUntilReady(audioInput) else { break }
                        audioInput.append(sample)
                    }
                    audioInput.markAsFinished()
                }

                let seconds = Int((last.presentationTimeStamp.seconds - startTime.seconds).rounded())
                writer.finishWriting {
                    let ok = writer.status == .completed
                    DispatchQueue.main.async { completion(ok ? max(seconds, 1) : nil) }
                }
            } catch {
                DispatchQueue.main.async { completion(nil) }
            }
        }
    }
}
