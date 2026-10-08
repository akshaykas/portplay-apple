import AVFoundation
import os

/// A small ring of audio samples between two threads. On Mac the dongle's
/// sound and the speakers run on separate clocks, so the game audio passes
/// through one of these, which keeps just enough cushion to avoid crackles.
final class AudioRing: @unchecked Sendable {
    let channels: Int

    private let capacity: Int
    private let target: Int
    private var storage: [UnsafeMutablePointer<Float>]
    private var written = 0
    private var read = 0
    private var primed = false
    private let lockPointer: UnsafeMutablePointer<os_unfair_lock>

    /// `capacity` and `target` are in frames. `target` is the cushion playback keeps.
    init(channels: Int, capacity: Int, target: Int) {
        self.channels = max(channels, 1)
        self.capacity = capacity
        self.target = target
        storage = (0..<max(channels, 1)).map { _ in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
            pointer.initialize(repeating: 0, count: capacity)
            return pointer
        }
        lockPointer = .allocate(capacity: 1)
        lockPointer.initialize(to: os_unfair_lock())
    }

    deinit {
        for pointer in storage {
            pointer.deallocate()
        }
        lockPointer.deallocate()
    }

    private func lock() { os_unfair_lock_lock(lockPointer) }
    private func unlock() { os_unfair_lock_unlock(lockPointer) }

    // MARK: Writing

    func write(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard frames > 0, buffers.count > 0 else { return }
        lock()
        for channel in 0..<channels {
            // Mono sources fill both sides
            let source = buffers[min(channel, buffers.count - 1)]
            guard let samples = source.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let target = storage[channel]
            for i in 0..<frames {
                target[(written + i) % capacity] = samples[i]
            }
        }
        written += frames
        // Too much backed up: drop the oldest
        if written - read > capacity {
            read = written - capacity
        }
        unlock()
    }

    // MARK: Reading

    /// For playback on the audio thread. Waits for a small cushion before starting,
    /// and skips ahead if it falls too far behind. Returns false when it wrote silence.
    func readForPlayback(_ buffers: UnsafeMutableAudioBufferListPointer, frames: Int) -> Bool {
        lock()
        defer { unlock() }

        let available = written - read
        if !primed {
            guard available >= target + frames else {
                Self.silence(buffers)
                return false
            }
            primed = true
        }
        if available < frames {
            primed = false
            Self.silence(buffers)
            return false
        }
        // Clock drift built up extra delay, so catch up
        if available > target * 4 + frames {
            read = written - (target + frames)
        }

        for (index, buffer) in buffers.enumerated() {
            guard let samples = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let source = storage[min(index, channels - 1)]
            for i in 0..<frames {
                samples[i] = source[(read + i) % capacity]
            }
        }
        read += frames
        return true
    }

    /// Adds whatever is waiting, up to `frames`, on top of `channelData`. Used to put
    /// a microphone into recordings.
    func mixAvailable(into channelData: UnsafePointer<UnsafeMutablePointer<Float>>, channelCount: Int, frames: Int, gain: Float) {
        lock()
        defer { unlock() }

        // Keep the microphone close to the game audio in time
        let maxBacklog = frames * 4
        if written - read > maxBacklog {
            read = written - maxBacklog
        }
        let count = min(frames, written - read)
        guard count > 0 else { return }

        for channel in 0..<channelCount {
            let target = channelData[channel]
            let source = storage[min(channel, channels - 1)]
            for i in 0..<count {
                target[i] += source[(read + i) % capacity] * gain
            }
        }
        read += count
    }

    private static func silence(_ buffers: UnsafeMutableAudioBufferListPointer) {
        for buffer in buffers {
            if let data = buffer.mData {
                memset(data, 0, Int(buffer.mDataByteSize))
            }
        }
    }
}
