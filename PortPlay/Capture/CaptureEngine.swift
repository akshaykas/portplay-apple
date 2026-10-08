import AVFoundation
import QuartzCore

/// The resolution and frame rate the dongle is actually sending.
struct RunningMode: Equatable {
    let width: Int32
    let height: Int32
    let fps: Double

    var label: String { "\(width)x\(height) at \(Int(fps.rounded())) fps" }
}

/// What the dongle can do, used to grey out options it can't reach.
struct DeviceCaps: Equatable {
    let maxWidth: Int32
    let maxHeight: Int32
    let maxFps: Double

    static let unknown = DeviceCaps(maxWidth: .max, maxHeight: .max, maxFps: .infinity)
}

struct OpenedCapture {
    let mode: RunningMode
    /// The resolution PortPlay settled on, when it had to step down to reach the frame rate.
    let usedResolution: String?
    let caps: DeviceCaps
}

enum CaptureError: LocalizedError {
    case cannotAdd(String)

    var errorDescription: String? {
        switch self {
        case .cannotAdd(let name): return "PortPlay could not open \(name)."
        }
    }
}

/// Opens a capture dongle at the profile's resolution and frame rate and
/// delivers every frame to the FrameHub on a dedicated high priority queue.
final class CaptureEngine: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let hub: FrameHub

    private let sessionQueue = DispatchQueue(label: "PortPlay.session")
    private let videoQueue = DispatchQueue(label: "PortPlay.video", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var outputAdded = false

    init(hub: FrameHub) {
        self.hub = hub
        super.init()
        // BGRA keeps the renderer, screenshots and the encoders simple
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        // A late frame is worth less than the next one
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: videoQueue)
    }

    // MARK: Opening

    func open(
        _ device: AVCaptureDevice,
        resolution: String,
        fps: Int,
        completion: @escaping (Result<OpenedCapture, Error>) -> Void
    ) {
        let session = self.session
        let output = self.output

        sessionQueue.async { [weak self] in
            guard let self else { return }
            let choice = Self.chooseFormat(device, resolution: resolution, fps: fps)
            var locked = false

            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard session.canAddInput(input) else {
                    throw CaptureError.cannotAdd(device.localizedName)
                }
                session.addInput(input)

                if !self.outputAdded, session.canAddOutput(output) {
                    session.addOutput(output)
                    self.outputAdded = true
                }

                #if os(iOS)
                if session.isMultitaskingCameraAccessSupported {
                    session.isMultitaskingCameraAccessEnabled = true
                }
                #endif

                // Keep the device locked until the session is running, otherwise
                // the session can swap the format back to its own preset.
                try device.lockForConfiguration()
                locked = true
                if let choice {
                    device.activeFormat = choice.format
                    device.activeVideoMinFrameDuration = choice.frameDuration
                    device.activeVideoMaxFrameDuration = choice.frameDuration
                }
                session.commitConfiguration()

                if !session.isRunning {
                    session.startRunning()
                }
                device.unlockForConfiguration()
                locked = false

                let size = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
                let duration = device.activeVideoMinFrameDuration
                let runningFps = duration.seconds > 0 ? 1 / duration.seconds : (choice?.fps ?? Double(fps))
                let opened = OpenedCapture(
                    mode: RunningMode(width: size.width, height: size.height, fps: runningFps),
                    usedResolution: choice?.resolution,
                    caps: Self.caps(of: device)
                )
                DispatchQueue.main.async { completion(.success(opened)) }
            } catch {
                if locked { device.unlockForConfiguration() }
                session.commitConfiguration()
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    func close() {
        let session = self.session
        sessionQueue.async {
            if session.isRunning {
                session.stopRunning()
            }
            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            session.commitConfiguration()
        }
    }

    // MARK: Frames

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        hub.deliver(sampleBuffer, captureTime: hostSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        hub.noteDropped()
    }

    /// When the frame reached this device, on the same clock as CACurrentMediaTime.
    private func hostSeconds(_ pts: CMTime) -> CFTimeInterval {
        let host = CMClockGetHostTimeClock()
        let converted = CMSyncConvertTime(pts, from: session.synchronizationClock ?? host, to: host)
        let seconds = converted.seconds
        let now = CACurrentMediaTime()
        // Fall back to "now" if a device reports timestamps on some other clock
        return seconds.isFinite && abs(now - seconds) < 2 ? seconds : now
    }

    // MARK: Choosing a format

    private struct FormatChoice {
        let format: AVCaptureDevice.Format
        let frameDuration: CMTime
        let fps: Double
        let resolution: String?
    }

    /// For games, frame rate matters more than resolution. Start at the chosen
    /// resolution and step down until the dongle offers the chosen frame rate.
    /// If nothing matches, use the closest format it has.
    private static func chooseFormat(_ device: AVCaptureDevice, resolution: String, fps: Int) -> FormatChoice? {
        let wanted = Double(fps)
        let startIndex = Resolutions.all.firstIndex { $0.value == resolution } ?? 2

        for (value, _) in Resolutions.all[startIndex...] {
            let size = Resolutions.size(value)
            let matches = device.formats.compactMap { format -> (AVCaptureDevice.Format, AVFrameRateRange)? in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                guard dims.width == size.width, dims.height == size.height else { return nil }
                guard let range = format.videoSupportedFrameRateRanges.first(where: {
                    $0.maxFrameRate >= wanted - 1 && $0.minFrameRate <= wanted + 1
                }) else { return nil }
                return (format, range)
            }
            // Uncompressed formats skip a decode step, so prefer them when both work
            if let pick = matches.first(where: { !isCompressed($0.0) }) ?? matches.first {
                return FormatChoice(
                    format: pick.0,
                    frameDuration: duration(for: wanted, in: pick.1),
                    fps: min(wanted, pick.1.maxFrameRate),
                    resolution: value
                )
            }
        }

        let target = Resolutions.size(resolution)
        let targetPixels = Double(target.width) * Double(target.height)
        let scored = device.formats.compactMap { format -> (AVCaptureDevice.Format, AVFrameRateRange, Double)? in
            guard let range = format.videoSupportedFrameRateRanges.max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            let pixels = Double(dims.width) * Double(dims.height)
            let score = abs(pixels - targetPixels) / targetPixels + abs(range.maxFrameRate - wanted) / wanted
            return (format, range, score)
        }
        guard let best = scored.min(by: { $0.2 < $1.2 }) else { return nil }
        return FormatChoice(
            format: best.0,
            frameDuration: duration(for: wanted, in: best.1),
            fps: min(wanted, best.1.maxFrameRate),
            resolution: nil
        )
    }

    private static func duration(for fps: Double, in range: AVFrameRateRange) -> CMTime {
        let wanted = CMTime(value: 1, timescale: CMTimeScale(fps.rounded()))
        let fits = CMTimeCompare(wanted, range.minFrameDuration) >= 0 && CMTimeCompare(wanted, range.maxFrameDuration) <= 0
        // 59.94 and similar rates sit just under the whole number
        return fits ? wanted : range.minFrameDuration
    }

    private static func isCompressed(_ format: AVCaptureDevice.Format) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(format.formatDescription)
        return subtype == kCMVideoCodecType_JPEG || subtype == kCMVideoCodecType_JPEG_OpenDML
    }

    private static func caps(of device: AVCaptureDevice) -> DeviceCaps {
        var maxWidth: Int32 = 0
        var maxHeight: Int32 = 0
        var maxFps = 0.0
        for format in device.formats {
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            maxWidth = max(maxWidth, dims.width)
            maxHeight = max(maxHeight, dims.height)
            for range in format.videoSupportedFrameRateRanges {
                maxFps = max(maxFps, range.maxFrameRate)
            }
        }
        guard maxWidth > 0 else { return .unknown }
        return DeviceCaps(maxWidth: maxWidth, maxHeight: maxHeight, maxFps: maxFps > 0 ? maxFps : .infinity)
    }
}
