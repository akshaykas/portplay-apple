import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
import CoreAudio
#endif

/// One resolution and frame rate combination the dongle can deliver.
struct VideoMode: Identifiable, Hashable {
    let width: Int32
    let height: Int32
    let fps: Double

    var id: String { "\(width)x\(height)@\(Int(fps.rounded()))" }
    var label: String { "\(height)p \(Int(fps.rounded())) fps" }
}

/// Finds USB (UVC) capture dongles, shows their video and plays their audio.
///
/// Audio works differently per platform:
/// * iPad routes the dongle's USB audio through AVAudioEngine (see AudioPassthrough).
/// * Mac adds the dongle's audio device to the capture session and plays it
///   with AVCaptureAudioPreviewOutput.
@MainActor
final class CaptureManager: ObservableObject {
    enum Status: Equatable {
        case starting
        case denied
        case waitingForDevice
        case running
        case interrupted(String)
        case failed(String)
    }

    #if os(macOS)
    /// Which audio input the Mac should play.
    enum AudioChoice: Equatable {
        case automatic
        case off
        case device(String)
    }
    #endif

    @Published private(set) var status: Status = .starting {
        didSet { updateIdleSleep() }
    }
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var activeDevice: AVCaptureDevice?
    @Published private(set) var modes: [VideoMode] = []
    @Published private(set) var activeMode: VideoMode?
    @Published private(set) var hasAudio = false
    @Published var isMuted = false {
        didSet { applyMute() }
    }

    #if os(macOS)
    @Published private(set) var audioSources: [AVCaptureDevice] = []
    @Published private(set) var activeAudio: AVCaptureDevice?
    @Published private(set) var audioChoice: AudioChoice = .automatic
    #endif

    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "PortPlay.session")
    private let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.external],
        mediaType: .video,
        position: .unspecified
    )
    private var devicesObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var started = false

    #if os(iOS)
    private let audio = AudioPassthrough()
    #else
    private let audioOutput = AVCaptureAudioPreviewOutput()
    private let audioDiscovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.microphone, .external],
        mediaType: .audio,
        position: .unspecified
    )
    private var audioObservation: NSKeyValueObservation?
    private var sleepActivity: NSObjectProtocol?
    #endif

    // MARK: Startup

    func start() async {
        guard !started else { return }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                status = .denied
                return
            }
        default:
            status = .denied
            return
        }

        // Game audio arrives as a USB microphone, so ask for that too.
        // Video still works if the person says no.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        started = true
        #if os(iOS)
        session.automaticallyConfiguresApplicationAudioSession = false
        #else
        audioOutput.volume = isMuted ? 0 : 1
        audioObservation = audioDiscovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshAudioSources() }
        }
        #endif
        observeNotifications()

        devicesObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.refreshDevices() }
        }
    }

    func retry() {
        if let device = activeDevice ?? devices.first {
            select(device)
        } else {
            refreshDevices()
        }
    }

    // MARK: Device and mode selection

    func select(_ device: AVCaptureDevice) {
        activeDevice = device
        let available = Self.modes(for: device)
        modes = available
        configure(device: device, mode: Self.preferredMode(in: available))
    }

    func select(_ mode: VideoMode) {
        guard let device = activeDevice else { return }
        configure(device: device, mode: mode)
    }

    #if os(macOS)
    func selectAudio(_ choice: AudioChoice) {
        audioChoice = choice
        guard let device = activeDevice else { return }
        configure(device: device, mode: activeMode)
    }

    private func refreshAudioSources() {
        let usb = Self.usbAudioDevices(from: audioDiscovery.devices)
        let changed = usb.map(\.uniqueID) != audioSources.map(\.uniqueID)
        audioSources = usb
        // Pick up a dongle's audio that appears a moment after its video.
        if changed, status == .running, let device = activeDevice {
            configure(device: device, mode: activeMode)
        }
    }
    #endif

    private func refreshDevices() {
        devices = discovery.devices

        if let current = activeDevice, devices.contains(current) { return }

        if let first = devices.first {
            select(first)
        } else {
            activeDevice = nil
            modes = []
            activeMode = nil
            stopAudio()
            stopSession()
            status = .waitingForDevice
        }
    }

    private func configure(device: AVCaptureDevice, mode: VideoMode?) {
        activeMode = mode
        let session = self.session

        #if os(macOS)
        let audioDevice = Self.audioDevice(for: device, choice: audioChoice, in: audioSources)
        let audioOutput = self.audioOutput
        #endif

        sessionQueue.async { [weak self] in
            var errorMessage: String?
            var audioName: String?

            session.beginConfiguration()
            for input in session.inputs {
                session.removeInput(input)
            }
            do {
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                    #if os(iOS)
                    if session.isMultitaskingCameraAccessSupported {
                        session.isMultitaskingCameraAccessEnabled = true
                    }
                    #endif
                    // The format has to be set after the input is added,
                    // otherwise the session preset overrides it.
                    if let mode {
                        try Self.apply(mode, to: device)
                    }
                } else {
                    errorMessage = "PortPlay could not open \(device.localizedName)."
                }
            } catch {
                errorMessage = error.localizedDescription
            }

            #if os(macOS)
            if errorMessage == nil,
               let audioDevice,
               let audioInput = try? AVCaptureDeviceInput(device: audioDevice),
               session.canAddInput(audioInput) {
                session.addInput(audioInput)
                audioName = audioDevice.uniqueID
                if !session.outputs.contains(audioOutput), session.canAddOutput(audioOutput) {
                    session.addOutput(audioOutput)
                }
            }
            #endif

            session.commitConfiguration()

            if errorMessage == nil, !session.isRunning {
                session.startRunning()
            }

            let finalError = errorMessage
            let finalAudio = audioName
            Task { @MainActor in self?.didConfigure(error: finalError, audioID: finalAudio) }
        }
    }

    private func didConfigure(error: String?, audioID: String?) {
        if let error {
            status = .failed(error)
            return
        }
        status = .running
        #if os(iOS)
        updateAudio()
        #else
        activeAudio = audioSources.first { $0.uniqueID == audioID }
        hasAudio = activeAudio != nil
        #endif
    }

    private func stopSession() {
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

    // MARK: Audio

    private func applyMute() {
        #if os(iOS)
        audio.setMuted(isMuted)
        #else
        audioOutput.volume = isMuted ? 0 : 1
        #endif
    }

    private func stopAudio() {
        #if os(iOS)
        audio.stop()
        #else
        activeAudio = nil
        #endif
        hasAudio = false
    }

    #if os(iOS)
    private func updateAudio() {
        guard status == .running else {
            stopAudio()
            return
        }
        hasAudio = audio.restart(muted: isMuted)
    }
    #endif

    // MARK: Keeping the screen awake

    private func updateIdleSleep() {
        #if os(iOS)
        UIApplication.shared.isIdleTimerDisabled = (status == .running)
        #else
        if status == .running {
            if sleepActivity == nil {
                sleepActivity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated],
                    reason: "Showing console video"
                )
            }
        } else if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        #endif
    }

    // MARK: Notifications

    private func observeNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Usually the dongle was unplugged or reset. Give it a moment, then reconnect.
                try? await Task.sleep(for: .seconds(1))
                self?.retry()
            }
        })

        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: session,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            Task { @MainActor in self?.handleInterruption(reason) }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.activeDevice != nil else { return }
                self.status = .running
                self.updateAudio()
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Only react to hardware coming and going, not to our own route changes.
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in self?.updateAudio() }
        })
        #endif
    }

    #if os(iOS)
    private func handleInterruption(_ reason: AVCaptureSession.InterruptionReason?) {
        stopAudio()

        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            status = .interrupted("Video pauses when PortPlay shares the screen. Make PortPlay full screen to keep playing.")
        case .videoDeviceInUseByAnotherClient:
            status = .interrupted("Another app is using the capture dongle.")
        case .videoDeviceNotAvailableDueToSystemPressure:
            status = .interrupted("Video paused because the iPad is running hot.")
        default:
            status = .interrupted("Video paused.")
        }
    }
    #endif

    // MARK: Format helpers

    nonisolated private static func modes(for device: AVCaptureDevice) -> [VideoMode] {
        var seen = Set<String>()
        var result: [VideoMode] = []
        for format in device.formats {
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            for range in format.videoSupportedFrameRateRanges {
                let mode = VideoMode(width: size.width, height: size.height, fps: range.maxFrameRate)
                if seen.insert(mode.id).inserted {
                    result.append(mode)
                }
            }
        }
        return result.sorted {
            let a = Int($0.width) * Int($0.height)
            let b = Int($1.width) * Int($1.height)
            return a != b ? a > b : $0.fps > $1.fps
        }
    }

    /// Prefers 1080p or lower at 50 fps or more, since games feel better at 60.
    nonisolated private static func preferredMode(in modes: [VideoMode]) -> VideoMode? {
        let upTo1080 = modes.filter { $0.height <= 1080 }
        return upTo1080.first { $0.fps >= 50 } ?? upTo1080.first ?? modes.first
    }

    nonisolated private static func apply(_ mode: VideoMode, to device: AVCaptureDevice) throws {
        func matches(_ range: AVFrameRateRange) -> Bool {
            abs(range.maxFrameRate - mode.fps) < 0.5
        }

        guard let format = device.formats.first(where: { format in
            let size = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            return size.width == mode.width
                && size.height == mode.height
                && format.videoSupportedFrameRateRanges.contains(where: matches)
        }) else { return }

        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        device.activeFormat = format
        if let range = format.videoSupportedFrameRateRanges.first(where: matches) {
            device.activeVideoMinFrameDuration = range.minFrameDuration
            device.activeVideoMaxFrameDuration = range.minFrameDuration
        }
    }

    // MARK: Mac audio helpers

    #if os(macOS)
    /// Only USB inputs, so PortPlay never plays the built-in or a Bluetooth mic back
    /// through the speakers.
    nonisolated private static func usbAudioDevices(from devices: [AVCaptureDevice]) -> [AVCaptureDevice] {
        var seen = Set<String>()
        return devices.filter { device in
            UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeUSB
                && seen.insert(device.uniqueID).inserted
        }
    }

    /// Finds the audio half of the dongle. Dongles show up as a separate video
    /// device and audio device, so this matches them by USB IDs, then by name.
    nonisolated private static func audioDevice(
        for video: AVCaptureDevice,
        choice: AudioChoice,
        in candidates: [AVCaptureDevice]
    ) -> AVCaptureDevice? {
        switch choice {
        case .off:
            return nil
        case .device(let id):
            return candidates.first { $0.uniqueID == id }
        case .automatic:
            if let ids = usbIDs(video.modelID),
               let match = candidates.first(where: { usbIDs($0.modelID) == ids }) {
                return match
            }
            let prefix = String(video.localizedName.lowercased().prefix(6))
            if !prefix.isEmpty,
               let match = candidates.first(where: { $0.localizedName.lowercased().hasPrefix(prefix) }) {
                return match
            }
            return candidates.count == 1 ? candidates.first : nil
        }
    }

    /// Pulls "VendorID_123 ProductID_456" out of a modelID, when present.
    nonisolated private static func usbIDs(_ modelID: String) -> String? {
        guard let range = modelID.range(
            of: #"VendorID_\d+ ProductID_\d+"#,
            options: .regularExpression
        ) else { return nil }
        return String(modelID[range])
    }
    #endif
}
