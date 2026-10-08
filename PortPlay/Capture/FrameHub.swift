import AVFoundation
import QuartzCore

/// Receives every frame and every game audio buffer, and hands them to whatever
/// needs them: the renderer, a recording, the instant replay buffer and picture in picture.
///
/// Video and audio share one timeline: host time in seconds, the same clock as
/// CACurrentMediaTime. That keeps recordings in sync without any extra bookkeeping.
final class FrameHub: @unchecked Sendable {
    private let lock = NSLock()

    private var renderer: VideoRenderer?
    private var recorder: ClipRecorder?
    private var replay: ReplayBuffer?
    private var pip: PiPManager?

    private var latestBuffer: CVPixelBuffer?
    private var arrivals: [CFTimeInterval] = []
    private var droppedCount = 0

    // MARK: Wiring, from the main thread

    func attach(renderer: VideoRenderer) {
        lock.withLock { self.renderer = renderer }
    }

    func setRecorder(_ recorder: ClipRecorder?) {
        lock.withLock { self.recorder = recorder }
    }

    func setReplay(_ replay: ReplayBuffer?) {
        lock.withLock { self.replay = replay }
    }

    /// Picture in picture only receives frames while it is starting or showing.
    func setPiP(_ pip: PiPManager?) {
        lock.withLock { self.pip = pip }
    }

    // MARK: Frames, from the capture queue

    func deliver(_ sampleBuffer: CMSampleBuffer, captureTime: CFTimeInterval) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()

        lock.lock()
        latestBuffer = pixelBuffer
        arrivals.append(now)
        if let first = arrivals.first, now - first > 2 {
            arrivals.removeAll { now - $0 > 1 }
        }
        let renderer = self.renderer
        let recorder = self.recorder
        let replay = self.replay
        let pip = self.pip
        lock.unlock()

        // Drawing comes first so nothing else adds to the delay on screen
        renderer?.render(pixelBuffer, captureTime: captureTime)

        let time = CMTime(seconds: captureTime, preferredTimescale: 1_000_000_000)
        recorder?.appendVideo(pixelBuffer, at: time)
        replay?.appendVideo(pixelBuffer, at: time)
        pip?.enqueue(pixelBuffer, at: time)
    }

    func noteDropped() {
        lock.withLock { droppedCount += 1 }
    }

    // MARK: Audio, from the audio thread

    /// `time` is when the sound should line up with the picture, with audio sync already added.
    func deliverAudio(_ buffer: AVAudioPCMBuffer, at time: CMTime) {
        lock.lock()
        let recorder = self.recorder
        let replay = self.replay
        lock.unlock()
        recorder?.appendAudio(buffer, at: time)
        replay?.appendAudio(buffer, at: time)
    }

    // MARK: Reading, from the main thread

    var latest: CVPixelBuffer? {
        lock.withLock { latestBuffer }
    }

    var framesPerSecond: Int {
        let now = CACurrentMediaTime()
        return lock.withLock { arrivals.filter { now - $0 <= 1 }.count }
    }

    var dropped: Int {
        lock.withLock { droppedCount }
    }

    func reset() {
        lock.withLock {
            latestBuffer = nil
            arrivals.removeAll()
            droppedCount = 0
        }
    }
}
