import AVFoundation
import CoreVideo
import ImageIO
import UniformTypeIdentifiers
import VideoToolbox

/// Small conversions shared by recording, instant replay and screenshots.
enum MediaBuffers {
    /// Wraps PCM audio in a sample buffer an asset writer accepts. The audio is copied.
    static func audioSampleBuffer(_ buffer: AVAudioPCMBuffer, at time: CMTime) -> CMSampleBuffer? {
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &format
        ) == noErr, let format else { return nil }

        let rate = CMTimeScale(buffer.format.sampleRate.rounded())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: rate),
            presentationTimeStamp: time.convertScale(rate, method: .default),
            decodeTimeStamp: .invalid
        )

        var sampleBuffer: CMSampleBuffer?
        guard CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: nil,
            dataReady: false,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: format,
            sampleCount: CMItemCount(buffer.frameLength),
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 0,
            sampleSizeArray: nil,
            sampleBufferOut: &sampleBuffer
        ) == noErr, let sampleBuffer else { return nil }

        guard CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            bufferList: buffer.audioBufferList
        ) == noErr else { return nil }

        return sampleBuffer
    }

    /// A private copy, since audio taps may reuse their buffers.
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            guard let from = source[index].mData, let to = target[index].mData else { continue }
            let bytes = min(source[index].mDataByteSize, target[index].mDataByteSize)
            memcpy(to, from, Int(bytes))
            target[index].mDataByteSize = bytes
        }
        return copy
    }

    /// AAC settings that suit the game audio's format.
    static func aacSettings(for format: AVAudioFormat) -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: min(Int(format.channelCount), 2),
            AVSampleRateKey: min(format.sampleRate, 48_000),
            AVEncoderBitRateKey: 192_000,
        ]
    }

    /// Bitrate that keeps 1080p60 sharp without huge files. Same formula as the Windows version.
    static func bitrate(width: Int32, height: Int32, fps: Double, forReplay: Bool) -> Int {
        let pixelsPerSecond = Double(width) * Double(height) * fps
        let bits = pixelsPerSecond * (forReplay ? 0.05 : 0.08)
        return Int(min(max(bits, 2_500_000), 16_000_000))
    }

    /// The frame at full resolution as a PNG.
    static func png(from pixelBuffer: CVPixelBuffer) -> Data? {
        var image: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &image)
        guard let image else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
