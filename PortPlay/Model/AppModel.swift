import AVFoundation
import QuartzCore
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let actionLabel: String?
    let action: (() -> Void)?

    static func == (a: Toast, b: Toast) -> Bool { a.id == b.id }
}

struct Tip: Identifiable, Equatable {
    let id: String
    let title: String
    let text: String
}

struct HUDValues: Equatable {
    enum Grade { case none, good, ok, bad }
    var latency = "n/a"
    var latencyGrade = Grade.none
    var fps = "--"
    var dropped = "--"
    var audio = "--"
    var signal = "--"
    var scale = "--"
    var mode = "--"
}

/// Values that change several times a second. Kept apart from AppModel so updating
/// them only redraws the stats box and recording timer, not the whole interface.
@MainActor
final class LiveStats: ObservableObject {
    @Published var hud = HUDValues()
    @Published var recordingElapsed: TimeInterval = 0
}

/// Everything the app does, in one place. Mirrors renderer.js in the Windows version.
@MainActor
final class AppModel: ObservableObject {
    enum Screen: Equatable {
        case starting
        case connecting
        case denied
        case noDevice
        case disconnected
        case running
        case interrupted(String)
        case failed(title: String, detail: String)
    }

    // MARK: Published state

    @Published private(set) var screen = Screen.starting
    @Published private(set) var noSignal = false

    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var currentDevice: AVCaptureDevice?
    @Published private(set) var mode: RunningMode?
    @Published private(set) var caps = DeviceCaps.unknown
    /// The resolution actually running, which can be lower than the profile's.
    @Published private(set) var runningResolution = "1920x1080"

    @Published private(set) var profiles: [NamedProfile]
    @Published private(set) var activeProfileName: String
    @Published private(set) var prefs: Prefs

    @Published private(set) var audioSources: [AudioSource] = []
    @Published private(set) var autoAudio: AudioSource?
    @Published private(set) var gameAudioRunning = false

    @Published private(set) var isRecording = false
    @Published private(set) var replayArmed = false
    @Published private(set) var pipActive = false
    @Published private(set) var flashToken = 0

    @Published private(set) var settingsOpen = false
    @Published private(set) var controlsVisible = true
    @Published private(set) var toasts: [Toast] = []
    @Published private(set) var tip: Tip?
    @Published private(set) var controllerStatus = ""
    @Published var isTypingName = false

    /// Fast-changing numbers, observed only by the views that show them.
    let live = LiveStats()
    /// Not published: hovering the controls shouldn't redraw anything.
    var pointerOnControls = false {
        didSet { wake() }
    }

    // MARK: Engines

    let hub: FrameHub
    let capture: CaptureEngine
    let renderer: VideoRenderer?
    let pip: PiPManager
    private let audio = GameAudio()
    private let gamepad = GamepadInput()
    #if os(macOS)
    private let floating = FloatingPlayer()
    #endif
    private let store: SettingsStore

    private var recorder: ClipRecorder?
    private var replay: ReplayBuffer?
    private var deviceProfiles: [String: String]
    private var dismissedTips: Set<String>
    private var shownTips = Set<String>()

    private var discovery: AVCaptureDevice.DiscoverySession?
    private var discoveryObservation: NSKeyValueObservation?
    private var observers: [NSObjectProtocol] = []
    private var launched = false
    private var startToken: UUID?
    private var deviceChangeTask: Task<Void, Never>?
    private var tickTimer: Timer?
    private var tickCount = 0
    private var lastActivity = CACurrentMediaTime()

    // Signal monitor
    private var darkSeconds = 0
    private var slowSeconds = 0
    private var droppedHistory: [Int] = []

    init() {
        let hub = FrameHub()
        let store = SettingsStore()
        self.hub = hub
        self.store = store
        capture = CaptureEngine(hub: hub)
        renderer = VideoRenderer()
        pip = PiPManager(hub: hub)

        let storedProfiles = store.profiles
        var active = store.activeProfile
        if !storedProfiles.contains(where: { $0.name == active }) {
            active = storedProfiles[0].name
        }
        profiles = storedProfiles
        activeProfileName = active
        prefs = store.prefs
        deviceProfiles = store.deviceProfiles
        dismissedTips = store.dismissedTips

        if let renderer {
            hub.attach(renderer: renderer)
        }

        // Runs on an audio thread
        audio.onBuffer = { @Sendable buffer, time in
            hub.deliverAudio(buffer, at: time)
        }
        pip.onActiveChange = { [weak self] active in
            self?.pipActive = active
        }
        pip.onFailure = { [weak self] in
            self?.toast("Picture in picture isn't available right now")
        }
        #if os(macOS)
        floating.onClose = { [weak self] in
            self?.pipActive = false
        }
        floating.onDoubleClick = { [weak self] in
            self?.floating.close()
            NSApplication.shared.activate()
            NSApplication.shared.windows.first { $0.isVisible && !($0 is NSPanel) }?.makeKeyAndOrderFront(nil)
        }
        #endif
        gamepad.onAction = { [weak self] action in
            self?.handleGamepad(action)
        }
        gamepad.onStatusChange = { [weak self] status in
            self?.controllerStatus = status
        }
        gamepad.onConnect = { [weak self] in
            self?.toast("Controller connected. Hold Select and press A for a screenshot.", duration: 5)
        }

        applyRenderer()
        audio.setVolume(prefs.volume, muted: prefs.muted)
        audio.setDelay(ms: profile.audioDelay)
    }

    // MARK: Derived values

    var profile: Profile {
        profiles.first { $0.name == activeProfileName }?.profile ?? Profile()
    }

    var isRunning: Bool { screen == .running }

    var filterActive: Bool { profile.filter != .off && !prefs.lowLatency }

    #if os(iOS)
    nonisolated static let isMac = false
    #else
    nonisolated static let isMac = true
    #endif

    // MARK: Startup

    func launch() async {
        guard !launched else { return }
        launched = true

        if renderer == nil {
            screen = .failed(title: "This device can't draw the picture", detail: "PortPlay needs Metal graphics, which isn't available here.")
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                screen = .denied
                return
            }
        default:
            screen = .denied
            return
        }

        // The dongle's game sound arrives as a microphone, so ask for that too.
        // Video still works if the person says no.
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        }

        observeNotifications()
        gamepad.begin()
        startTicking()
        wake()

        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified)
        self.discovery = discovery
        discoveryObservation = discovery.observe(\.devices, options: [.initial, .new]) { [weak self] _, _ in
            Task { @MainActor in self?.devicesChanged() }
        }
    }

    // MARK: Devices

    /// Names and USB IDs that HDMI to USB dongles usually report.
    /// 345f and 534d are the vendor IDs of the MacroSilicon chips inside most of them.
    private static let capturePatterns = [
        #"usb\s?\d?\.?\d?\s?video"#, #"ms21\d\d"#, #"345f"#, #"534d"#,
        #"capture"#, #"hdmi"#, #"cam link"#, #"uvc"#,
    ]

    private static func looksLikeCapture(_ text: String) -> Bool {
        capturePatterns.contains { text.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }
    }

    private func devicesChanged() {
        // Wait for the dust to settle when a USB device is plugged in or removed
        deviceChangeTask?.cancel()
        deviceChangeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self.refreshDevices()
        }
    }

    private func refreshDevices() {
        // An iPhone nearby can show up as a camera through Continuity Camera. It's never a dongle.
        devices = (discovery?.devices ?? []).filter { !$0.isContinuityCamera }

        if let current = currentDevice {
            if devices.contains(current) { return }
            stopCapture()
            screen = .disconnected
        }
        autoConnect()
    }

    private func autoConnect() {
        guard currentDevice == nil, startToken == nil else { return }
        // Prefer the last used device, then anything that looks like a dongle
        let pick = devices.first { $0.uniqueID == prefs.videoDevice }
            ?? devices.first { Self.looksLikeCapture("\($0.localizedName) \($0.modelID)") }
            ?? (devices.count == 1 ? devices.first : nil)

        if let pick {
            start(pick)
        } else if screen != .disconnected {
            screen = .noDevice
        }
    }

    func selectDevice(_ device: AVCaptureDevice) {
        start(device)
    }

    func retry() {
        if let device = currentDevice ?? devices.first(where: { $0.uniqueID == prefs.videoDevice }) ?? devices.first {
            start(device)
        } else {
            screen = .noDevice
        }
    }

    // MARK: Starting and stopping

    private func start(_ device: AVCaptureDevice) {
        stopCapture()
        screen = .connecting

        // Each dongle brings back the profile it was last used with
        if let mapped = deviceProfiles[device.localizedName],
           mapped != activeProfileName,
           profiles.contains(where: { $0.name == mapped }) {
            activeProfileName = mapped
            store.activeProfile = mapped
            applyProfile()
            toast("Loaded your \(mapped) profile")
        }

        let wanted = profile
        let token = UUID()
        startToken = token

        capture.open(device, resolution: wanted.resolution, fps: wanted.framerate) { [weak self] result in
            guard let self, self.startToken == token else { return }
            self.startToken = nil
            switch result {
            case .success(let opened):
                self.didOpen(device, opened, wanted: wanted)
            case .failure(let error):
                self.capture.close()
                self.screen = .failed(
                    title: "Could not open the capture device",
                    detail: "\(error.localizedDescription)\nClose other apps that might be using it, or try another USB port."
                )
            }
        }
    }

    private func didOpen(_ device: AVCaptureDevice, _ opened: OpenedCapture, wanted: Profile) {
        currentDevice = device
        mode = opened.mode
        caps = opened.caps
        hub.reset()
        resetMonitor()

        prefs.videoDevice = device.uniqueID
        savePrefs()
        deviceProfiles[device.localizedName] = activeProfileName
        store.deviceProfiles = deviceProfiles

        runningResolution = opened.usedResolution ?? wanted.resolution
        if let used = opened.usedResolution, used != wanted.resolution {
            toast(
                "Running at \(Resolutions.label(used)), since your dongle doesn't offer \(wanted.framerate) fps at \(Resolutions.label(wanted.resolution))",
                duration: 6
            )
        }

        screen = .running
        #if os(iOS)
        pip.beginFeeding()
        #endif
        startAudio(for: device)
        checkCapabilities(wanted: wanted)
        startReplayIfWanted()
        wake()
    }

    private func stopCapture() {
        startToken = nil
        if isRecording { finishRecording() }
        stopReplay()
        pip.stop()
        #if os(macOS)
        floating.close()
        #endif
        audio.stop()
        gameAudioRunning = false
        capture.close()
        renderer?.clear()
        hub.reset()
        currentDevice = nil
        mode = nil
        noSignal = false
        resetMonitor()
    }

    /// A dongle that can't reach 50 fps is often on a slow port or hub.
    private func checkCapabilities(wanted: Profile) {
        guard wanted.framerate >= 50, caps.maxFps.isFinite, caps.maxFps < 49 else { return }
        #if os(iOS)
        let advice = "HDMI dongles often slow down through a USB hub or adapter. Try plugging it straight into the iPad. If it already is, the dongle may be a USB 2 model."
        #else
        let advice = "HDMI dongles often slow down in a USB 2 port or hub. Try a USB-C or USB 3 port directly on your Mac. If it already is, the dongle may be a USB 2 model."
        #endif
        showTip("slow-dongle", "Your dongle tops out at \(Int(caps.maxFps.rounded())) fps", advice)
    }

    // MARK: Game audio

    private func startAudio(for device: AVCaptureDevice) {
        let sources = GameAudio.availableSources()
        audioSources = sources
        let auto = autoDongleAudio(for: device, in: sources)
        autoAudio = auto

        let saved = prefs.gameAudio[device.localizedName]
        let chosen: AudioSource?
        switch saved {
        case .off?:
            chosen = nil
        case .device(let id, let name)?:
            chosen = sources.first { $0.id == id } ?? sources.first { $0.name == name } ?? auto
        case nil:
            chosen = auto
        }

        guard let chosen else {
            gameAudioRunning = false
            if saved != .off { explainMissingAudio(failed: false) }
            return
        }

        do {
            #if os(iOS)
            try audio.start(chosen)
            #else
            let mic = sources.first { $0.id == prefs.micID && $0.id != chosen.id }
            try audio.start(chosen, mic: mic, micLevel: prefs.micLevel)
            #endif
            gameAudioRunning = true
        } catch {
            gameAudioRunning = false
            explainMissingAudio(failed: true)
        }
    }

    /// Finds the dongle's sound, which shows up as a separate audio input.
    private func autoDongleAudio(for video: AVCaptureDevice, in sources: [AudioSource]) -> AudioSource? {
        #if os(iOS)
        // iPad only lists USB inputs, and the dongle is almost always the only one
        return sources.first
        #else
        // Same USB vendor and product ID
        if let ids = Self.usbIDs(video.modelID),
           let match = sources.first(where: { Self.usbIDs($0.modelID) == ids }) {
            return match
        }
        // Same name, without anything in brackets
        let base = video.localizedName
            .replacingOccurrences(of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        if base.count > 3, let match = sources.first(where: { $0.name.lowercased().contains(base) }) {
            return match
        }
        // Names capture dongles usually give their sound
        if let match = sources.first(where: {
            Self.looksLikeCapture($0.name) || $0.name.range(of: "usb digital audio", options: .caseInsensitive) != nil
        }) {
            return match
        }
        // The only USB audio input is very likely the dongle
        let usb = sources.filter(\.isUSB)
        return usb.count == 1 ? usb[0] : nil
        #endif
    }

    private static func usbIDs(_ modelID: String) -> String? {
        guard let range = modelID.range(of: #"VendorID_\d+ ProductID_\d+"#, options: .regularExpression) else { return nil }
        return String(modelID[range])
    }

    /// Explains why there's no game sound, once the picture is up.
    private func explainMissingAudio(failed: Bool) {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            #if os(iOS)
            let text = "Your iPad isn't letting PortPlay use the microphone, and the dongle's sound arrives as one. Open Settings, find PortPlay, and turn on Microphone. Then reopen the app."
            #else
            let text = "Your Mac isn't letting PortPlay use the microphone, and the dongle's sound arrives as one. Open System Settings, go to Privacy & Security, then Microphone, and turn on PortPlay. Then reopen the app."
            #endif
            showTip("audio-blocked", "Game sound is blocked", text)
        } else if failed {
            showTip("audio-busy", "Couldn't open the game sound", "Another app may be using it. Close other apps that use the dongle, then reconnect.")
        } else {
            #if os(iOS)
            let text = "Your dongle's sound didn't show up. Unplug the dongle and plug it back in, or open settings and choose it under Game audio."
            #else
            let text = "Open settings with O and choose your dongle under Game audio. Its name usually matches the dongle, or says USB Digital Audio."
            #endif
            showTip("audio-missing", "Couldn't find the game sound", text)
        }
    }

    /// The game audio menu's current choice: nil for automatic.
    var gameAudioSelection: String? {
        guard let device = currentDevice else { return nil }
        switch prefs.gameAudio[device.localizedName] {
        case .off?: return "off"
        case .device(let id, _)?: return id
        case nil: return nil
        }
    }

    func setGameAudio(_ selection: String?) {
        guard let device = currentDevice else { return }
        switch selection {
        case nil:
            prefs.gameAudio[device.localizedName] = nil
        case "off"?:
            prefs.gameAudio[device.localizedName] = .off
        case let id?:
            let name = audioSources.first { $0.id == id }?.name ?? id
            prefs.gameAudio[device.localizedName] = .device(id: id, name: name)
        }
        savePrefs()
        audio.stop()
        startAudio(for: device)
    }

    /// Microphones for recordings, without the dongle itself.
    var micSources: [AudioSource] {
        audioSources.filter { $0.id != activeGameAudioID }
    }

    private var activeGameAudioID: String? {
        switch gameAudioSelection {
        case "off"?: return nil
        case let id?: return id
        case nil: return autoAudio?.id
        }
    }

    func setMic(_ id: String) {
        prefs.micID = id
        savePrefs()
        #if os(macOS)
        let source = audioSources.first { $0.id == id }
        if !audio.setMic(source, level: prefs.micLevel), source != nil {
            toast("Couldn't open that microphone")
        }
        #endif
    }

    func setMicLevel(_ level: Double) {
        prefs.micLevel = level
        savePrefs()
        #if os(macOS)
        audio.setMicLevel(level)
        #endif
    }

    // MARK: Volume and audio sync

    func setVolume(_ volume: Double) {
        prefs.volume = volume
        if prefs.muted && volume > 0 { prefs.muted = false }
        savePrefs()
        audio.setVolume(prefs.volume, muted: prefs.muted)
    }

    func toggleMute() {
        prefs.muted.toggle()
        savePrefs()
        audio.setVolume(prefs.volume, muted: prefs.muted)
    }

    func setAudioDelay(_ ms: Int) {
        setProfileValue { $0.audioDelay = ms }
        audio.setDelay(ms: ms)
    }

    // MARK: Profiles

    private func setProfileValue(_ change: (inout Profile) -> Void) {
        guard let index = profiles.firstIndex(where: { $0.name == activeProfileName }) else { return }
        change(&profiles[index].profile)
        store.profiles = profiles
    }

    private func applyProfile() {
        applyRenderer()
        audio.setDelay(ms: profile.audioDelay)
    }

    func switchProfile(_ name: String) {
        guard name != activeProfileName, profiles.contains(where: { $0.name == name }) else { return }
        let before = profile
        activeProfileName = name
        store.activeProfile = name
        if let device = currentDevice {
            deviceProfiles[device.localizedName] = name
            store.deviceProfiles = deviceProfiles
        }
        applyProfile()
        let after = profile
        if let device = currentDevice, before.resolution != after.resolution || before.framerate != after.framerate {
            start(device)
        }
    }

    func saveProfile(named raw: String) -> Bool {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            toast("Give the profile a name first")
            return false
        }
        guard !profiles.contains(where: { $0.name == name }) else {
            toast("A profile with that name already exists")
            return false
        }
        profiles.append(NamedProfile(name: String(name.prefix(24)), profile: profile))
        store.profiles = profiles
        switchProfile(String(name.prefix(24)))
        toast("Saved your \(name) profile")
        return true
    }

    func deleteProfile() {
        guard profiles.count > 1 else { return }
        let gone = activeProfileName
        guard let next = profiles.first(where: { $0.name != gone })?.name else { return }
        switchProfile(next)
        profiles.removeAll { $0.name == gone }
        deviceProfiles = deviceProfiles.filter { $0.value != gone }
        store.profiles = profiles
        store.deviceProfiles = deviceProfiles
        toast("Deleted the \(gone) profile")
    }

    func setResolution(_ value: String) {
        setProfileValue { $0.resolution = value }
        if let device = currentDevice { start(device) }
    }

    func setFrameRate(_ fps: Int) {
        setProfileValue { $0.framerate = fps }
        if let device = currentDevice { start(device) }
    }

    func isResolutionSupported(_ value: String) -> Bool {
        let size = Resolutions.size(value)
        return size.width <= caps.maxWidth && size.height <= caps.maxHeight
    }

    func isFrameRateSupported(_ fps: Int) -> Bool {
        Double(fps) <= caps.maxFps.rounded()
    }

    // MARK: Scaling and filters

    private func applyRenderer() {
        renderer?.configure(scaling: profile.scaling, filter: profile.filter, lowLatency: prefs.lowLatency)
    }

    func setScaling(_ mode: ScaleMode) {
        setProfileValue { $0.scaling = mode }
        applyRenderer()
    }

    func cycleScaling() {
        setScaling(profile.scaling.next)
        let fallback = profile.scaling.label
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            let text = self.renderer?.scaleText ?? ""
            self.toast("Scaling: \(text.isEmpty ? fallback : text)", duration: 1.5)
        }
    }

    func setFilter(_ filter: RetroFilter) {
        setProfileValue { $0.filter = filter }
        if prefs.lowLatency && filter != .off {
            setLowLatency(false)
            toast("Low latency mode is off so the filter can run")
        }
        applyRenderer()
    }

    func cycleFilter() {
        let next = profile.filter.next
        setFilter(next)
        toast("Filter: \(next.label)", duration: 1.5)
    }

    // MARK: Low latency mode

    func setLowLatency(_ on: Bool, announce: Bool = false) {
        prefs.lowLatency = on
        savePrefs()
        applyRenderer()
        if on {
            stopReplay()
        } else {
            startReplayIfWanted()
        }
        if announce {
            toast(on ? "Low latency mode on. Filters and instant replay are paused." : "Low latency mode off")
        }
    }

    // MARK: Stats

    func setStats(_ on: Bool) {
        prefs.stats = on
        savePrefs()
        if on { updateHUD() }
    }

    private func updateHUD() {
        var values = HUDValues()
        values.fps = isRunning ? "\(hub.framesPerSecond) fps" : "--"

        if let latency = renderer?.averageLatency {
            values.latency = "\(Int(latency.rounded())) ms"
            values.latencyGrade = latency < 50 ? .good : latency < 90 ? .ok : .bad
        }

        values.dropped = isRunning ? "\(hub.dropped)" : "--"
        values.audio = audio.latencyMs.map { "\(Int($0.rounded())) ms" } ?? "No audio"
        values.signal = mode?.label ?? "--"
        let scale = renderer?.scaleText ?? ""
        values.scale = scale.isEmpty ? "--" : scale

        var parts = [prefs.lowLatency ? "Low latency" : "Normal"]
        if filterActive { parts.append("\(profile.filter.label) filter") }
        if replay != nil { parts.append("replay on") }
        values.mode = parts.joined(separator: ", ")

        if values != live.hud { live.hud = values }
    }

    // MARK: Watching the signal

    private func resetMonitor() {
        darkSeconds = 0
        slowSeconds = 0
        droppedHistory = []
    }

    /// Runs once a second. Shows the waiting card and offers help when something looks wrong.
    private func checkSignal() {
        guard isRunning else { return }
        let fps = hub.framesPerSecond
        let noPicture = fps == 0 || Self.isBlack(hub.latest)

        darkSeconds = noPicture ? darkSeconds + 1 : 0
        let showWaiting = darkSeconds >= 4
        if noSignal != showWaiting { noSignal = showWaiting }
        if noPicture { return }

        // Frame rate well under what the dongle says it is sending
        let target = mode?.fps ?? 0
        slowSeconds = target >= 25 && Double(fps) < target * 0.75 ? slowSeconds + 1 : 0
        if slowSeconds >= 8 {
            #if os(iOS)
            let advice = "Try plugging the dongle straight into the iPad instead of through a hub, set your console's video output to 1080p, or pick a lower resolution in settings."
            #else
            let advice = "Try a USB-C or USB 3 port directly on your Mac, set your console's video output to 1080p, or pick a lower resolution in settings. Closing other apps that use the camera can help too."
            #endif
            showTip("low-fps", "Running at \(fps) fps instead of \(Int(target.rounded()))", advice)
        }

        // More than 30 dropped frames in 10 seconds
        droppedHistory.append(hub.dropped)
        if droppedHistory.count > 10 { droppedHistory.removeFirst() }
        if droppedHistory.count == 10, let first = droppedHistory.first, let last = droppedHistory.last, last - first > 30 {
            let lowLatencyHint = Self.isMac ? "low latency mode with G" : "low latency mode"
            showTip("dropped", "Frames are being dropped", "PortPlay is falling behind drawing the picture. Turn off retro filters and instant replay, or try \(lowLatencyHint).")
        }
    }

    /// Checks a 64 by 36 grid of pixels. Anything this dark is a console that's off or asleep.
    private nonisolated static func isBlack(_ pixelBuffer: CVPixelBuffer?) -> Bool {
        guard let pixelBuffer, CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return true }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self) else { return false }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var brightest = 0
        for gy in 0..<36 {
            let y = (gy * height) / 36 + height / 72
            for gx in 0..<64 {
                let x = (gx * width) / 64 + width / 128
                let p = base + y * stride + x * 4
                brightest = max(brightest, (Int(p[0]) + Int(p[1]) + Int(p[2])) / 3)
            }
        }
        return brightest < 24
    }

    // MARK: Screenshots, recording and instant replay

    private func needsStream() -> Bool {
        if isRunning, hub.latest != nil { return true }
        toast("Connect your console first")
        return false
    }

    func takeScreenshot() {
        guard needsStream(), let pixelBuffer = hub.latest else { return }
        flashToken += 1
        Task.detached(priority: .userInitiated) {
            let png = MediaBuffers.png(from: pixelBuffer)
            await MainActor.run {
                guard let png else {
                    self.toast("Couldn't take the screenshot")
                    return
                }
                let copied = CaptureSaver.copyImage(png)
                CaptureSaver.saveScreenshot(png) { result in
                    Task { @MainActor in
                        self.savedToast(result, copied ? "Screenshot copied and saved" : "Screenshot saved")
                    }
                }
            }
        }
    }

    func toggleRecording() {
        if isRecording {
            finishRecording()
            return
        }
        guard needsStream(), let mode else { return }
        do {
            let recorder = try ClipRecorder(url: CaptureSaver.temporaryVideoURL(), mode: mode, audioFormat: audio.format)
            self.recorder = recorder
            hub.setRecorder(recorder)
            live.recordingElapsed = 0
            isRecording = true
        } catch {
            toast("Couldn't start recording: \(error.localizedDescription)")
        }
    }

    private func finishRecording() {
        guard let recorder else { return }
        self.recorder = nil
        hub.setRecorder(nil)
        isRecording = false
        recorder.finish { url in
            guard let url else { return }
            CaptureSaver.saveVideo(at: url) { result in
                Task { @MainActor in self.savedToast(result, "Recording saved") }
            }
        }
    }

    private func startReplayIfWanted() {
        defer { replayArmed = replay != nil }
        guard replay == nil, isRunning, let mode, prefs.replay, !prefs.lowLatency else { return }
        guard let buffer = ReplayBuffer(mode: mode) else { return }
        replay = buffer
        hub.setReplay(buffer)
    }

    private func stopReplay() {
        hub.setReplay(nil)
        replay?.stop()
        replay = nil
        replayArmed = false
    }

    func setReplay(_ on: Bool) {
        prefs.replay = on
        savePrefs()
        if on {
            startReplayIfWanted()
        } else {
            stopReplay()
        }
    }

    func saveReplay() {
        guard needsStream() else { return }
        if prefs.lowLatency {
            toast(Self.isMac
                ? "Instant replay is paused in low latency mode. Press G to turn it off."
                : "Instant replay is paused in low latency mode. Turn it off to use replay.")
            return
        }
        guard prefs.replay, let replay else {
            setReplay(true)
            toast(Self.isMac
                ? "Instant replay is on. From now on, press V to save the last 30 seconds."
                : "Instant replay is on. From now on, tap the replay button to save the last 30 seconds.",
                duration: 5)
            return
        }
        guard replay.available >= 3 else {
            toast("Instant replay is still filling up")
            return
        }
        let url = CaptureSaver.temporaryVideoURL()
        replay.save(to: url, audioFormat: audio.format) { seconds in
            guard let seconds else {
                self.toast("Couldn't save the replay")
                return
            }
            CaptureSaver.saveVideo(at: url) { result in
                Task { @MainActor in self.savedToast(result, "Saved the last \(seconds) seconds") }
            }
        }
    }

    private func savedToast(_ result: Result<CaptureSaver.Saved, Error>, _ message: String) {
        switch result {
        case .success(let saved):
            #if os(macOS)
            if let file = saved.file {
                toast("\(message) to \(saved.place)", action: ("Show in Finder", { CaptureSaver.reveal(file) }))
                return
            }
            toast("\(message) to \(saved.place)")
            #else
            toast("\(message) to \(saved.place)", action: ("Open Photos", { CaptureSaver.openPhotos() }))
            #endif
        case .failure(let error):
            toast("Couldn't save: \(error.localizedDescription)")
        }
    }

    // MARK: Picture in picture and full screen

    /// Mac uses its own floating window. iPad uses the system's picture in picture.
    var pipSupported: Bool {
        Self.isMac || pip.isSupported
    }

    func togglePiP() {
        guard pipActive || needsStream() else { return }
        #if os(macOS)
        if floating.isOpen {
            floating.close()
        } else {
            let size = mode.map { CGSize(width: Int($0.width), height: Int($0.height)) } ?? CGSize(width: 16, height: 9)
            floating.show(session: capture.session, aspect: size)
            pipActive = true
        }
        #else
        pip.toggle()
        #endif
    }

    func toggleFullscreen() {
        #if os(macOS)
        let window = NSApplication.shared.keyWindow ?? NSApplication.shared.windows.first { $0.isVisible }
        window?.toggleFullScreen(nil)
        #endif
    }

    // MARK: Settings panel

    func toggleSettings() {
        setSettings(!settingsOpen)
    }

    func setSettings(_ open: Bool) {
        guard open != settingsOpen else { return }
        withAnimation(.easeOut(duration: 0.25)) { settingsOpen = open }
        wake()
    }

    // MARK: Controller

    private func handleGamepad(_ action: GamepadInput.Action) {
        wake()
        switch action {
        case .screenshot: takeScreenshot()
        case .record: toggleRecording()
        case .replay: saveReplay()
        case .fullscreen: toggleFullscreen()
        case .nextScaling: cycleScaling()
        case .nextFilter: cycleFilter()
        case .stats: setStats(!prefs.stats)
        }
    }

    // MARK: Controls hiding

    /// Shows the controls. They hide again after a few seconds without activity,
    /// unless settings are open or the pointer is on them. Cheap enough to call on
    /// every mouse move.
    func wake() {
        lastActivity = CACurrentMediaTime()
        if !controlsVisible {
            withAnimation(.easeOut(duration: 0.2)) { controlsVisible = true }
        }
    }

    private func hideControlsIfIdle() {
        guard controlsVisible, isRunning, !settingsOpen, !pointerOnControls else { return }
        guard CACurrentMediaTime() - lastActivity > (Self.isMac ? 2.5 : 4) else { return }
        withAnimation(.easeIn(duration: 0.3)) { controlsVisible = false }
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(true)
        #endif
    }

    /// iPad: tap the picture to show or hide the controls.
    func tapStage() {
        if controlsVisible && isRunning && !settingsOpen {
            withAnimation(.easeIn(duration: 0.25)) { controlsVisible = false }
        } else {
            wake()
        }
    }

    // MARK: Toasts and tips

    func toast(_ message: String, action: (String, () -> Void)? = nil, duration: TimeInterval = 3.8) {
        let toast = Toast(message: message, actionLabel: action?.0, action: action?.1)
        toasts.append(toast)
        if toasts.count > 3 { toasts.removeFirst(toasts.count - 3) }
        let lifetime = action == nil ? duration : duration + 2.5
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(lifetime))
            self.toasts.removeAll { $0.id == toast.id }
        }
    }

    func runToastAction(_ toast: Toast) {
        toast.action?()
        toasts.removeAll { $0.id == toast.id }
    }

    /// Each tip shows at most once per session, and never again once dismissed for good.
    private func showTip(_ id: String, _ title: String, _ text: String) {
        guard !dismissedTips.contains(id), !shownTips.contains(id), tip == nil else { return }
        shownTips.insert(id)
        withAnimation(.easeOut(duration: 0.25)) { tip = Tip(id: id, title: title, text: text) }
    }

    func closeTip(forever: Bool) {
        if forever, let tip {
            dismissedTips.insert(tip.id)
            store.dismissedTips = dismissedTips
        }
        withAnimation(.easeIn(duration: 0.2)) { tip = nil }
    }

    // MARK: Housekeeping

    private func savePrefs() {
        store.prefs = prefs
    }

    private func startTicking() {
        tickTimer?.invalidate()
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        tickCount += 1
        if prefs.stats { updateHUD() }
        if let recorder, isRecording {
            let elapsed = recorder.elapsed.rounded(.down)
            if live.recordingElapsed != elapsed { live.recordingElapsed = elapsed }
        }
        if tickCount % 4 == 0 { checkSignal() }
        hideControlsIfIdle()
    }

    private func observeNotifications() {
        let center = NotificationCenter.default

        observers.append(center.addObserver(
            forName: AVCaptureSession.runtimeErrorNotification,
            object: capture.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Usually the dongle was unplugged or reset. Give it a moment, then reconnect.
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                if let device = self.currentDevice, self.devices.contains(device) {
                    self.start(device)
                } else {
                    self.refreshDevices()
                }
            }
        })

        #if os(iOS)
        observers.append(center.addObserver(
            forName: AVCaptureSession.wasInterruptedNotification,
            object: capture.session,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
            let reason = raw.flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
            Task { @MainActor in self?.interrupted(reason) }
        })

        observers.append(center.addObserver(
            forName: AVCaptureSession.interruptionEndedNotification,
            object: capture.session,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, let device = self.currentDevice else { return }
                self.screen = .running
                self.startAudio(for: device)
            }
        })

        observers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            // Only react to hardware coming and going, not to PortPlay's own changes
            guard reason == .newDeviceAvailable || reason == .oldDeviceUnavailable else { return }
            Task { @MainActor in
                guard let self, let device = self.currentDevice, self.isRunning else { return }
                self.audio.stop()
                self.startAudio(for: device)
            }
        })
        #endif
    }

    #if os(iOS)
    private func interrupted(_ reason: AVCaptureSession.InterruptionReason?) {
        guard currentDevice != nil else { return }
        audio.stop()
        gameAudioRunning = false
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps:
            screen = .interrupted("Video pauses when PortPlay shares the screen. Make PortPlay full screen to keep playing.")
        case .videoDeviceInUseByAnotherClient:
            screen = .interrupted("Another app is using the capture dongle.")
        case .videoDeviceNotAvailableDueToSystemPressure:
            screen = .interrupted("Video paused because the iPad is running hot.")
        default:
            screen = .interrupted("Video paused.")
        }
    }
    #endif
}
