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

/// One line in Check my setup.
struct SetupCheck: Identifiable, Equatable {
    enum Status { case pending, good, warn, bad, info }
    let id: String
    let status: Status
    let title: String
    var text = ""
}

/// Why there's no game sound, for Check my setup.
enum AudioProblem: Equatable {
    case off, missing, blocked
    case failed(String)
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
    @Published private(set) var controllerLayout = GamepadInput.Layout(brand: .other, select: "Select", keys: [:])

    @Published private(set) var checkupOpen = false
    @Published private(set) var checks: [SetupCheck] = []
    @Published private(set) var checkupSummary = ""
    @Published private(set) var checkupRunning = false
    private var checkupToken = UUID()
    private var audioProblem: AudioProblem?
    @Published var isTypingName = false
    /// iPad apps are always full screen. On Mac this follows the window.
    @Published private(set) var isFullScreen = !AppModel.isMac

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
    #if os(macOS)
    private var audioDiscovery: AVCaptureDevice.DiscoverySession?
    private var audioDiscoveryObservation: NSKeyValueObservation?
    #endif
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
        gamepad.onLayoutChange = { [weak self] layout in
            if self?.controllerLayout != layout { self?.controllerLayout = layout }
        }
        gamepad.onConnect = { [weak self] in
            guard let self else { return }
            let layout = self.gamepad.layout
            let button = layout.keys[.screenshot]?.text ?? "A"
            self.toast("Controller connected. Hold \(layout.select) and press \(button) for a screenshot.", duration: 5)
        }

        applyRenderer()
        audio.setVolume(prefs.volume, muted: prefs.muted)
        audio.setDelay(ms: profile.audioDelay)
        #if os(macOS)
        observeFullScreen()
        #endif
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

        #if os(macOS)
        // A dongle's sound usually shows up a moment after its picture, so keep watching
        let audioDiscovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        self.audioDiscovery = audioDiscovery
        audioDiscoveryObservation = audioDiscovery.observe(\.devices, options: [.new]) { [weak self] _, _ in
            Task { @MainActor in self?.audioDevicesChanged() }
        }
        #endif
    }

    #if os(macOS)
    /// Starts the game sound once it appears, and moves on if it goes away.
    private func audioDevicesChanged() {
        guard let device = currentDevice else { return }
        let fresh = GameAudio.availableSources()
        guard fresh.map(\.id) != audioSources.map(\.id) else { return }

        let playing = gameAudioRunning && fresh.contains { $0.id == activeGameAudioID }
        if playing {
            audioSources = fresh
            autoAudio = autoDongleAudio(for: device, in: gameAudioSources)
        } else {
            audio.stop()
            startAudio(for: device)
        }
    }
    #endif

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
        audioProblem = nil
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
        audioSources = GameAudio.availableSources()
        // A saved choice of the Mac's own microphone is ignored too, so it can't feed back
        let sources = gameAudioSources
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
            audioProblem = saved == .off ? AudioProblem.off : AudioProblem.missing
            guard saved != .off else { return }
            #if os(macOS)
            // The sound may still be on its way, so only explain if it hasn't shown up
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard let self, self.currentDevice == device, !self.gameAudioRunning else { return }
                self.explainMissingAudio(failed: false)
            }
            #else
            explainMissingAudio(failed: false)
            #endif
            return
        }

        do {
            #if os(iOS)
            try audio.start(chosen)
            #else
            let mic = audioSources.first { $0.id == prefs.micID && $0.id != chosen.id }
            try audio.start(chosen, mic: mic, micLevel: prefs.micLevel)
            #endif
            gameAudioRunning = true
            audioProblem = nil
        } catch {
            gameAudioRunning = false
            audioProblem = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                ? AudioProblem.failed(error.localizedDescription)
                : AudioProblem.blocked
            explainMissingAudio(failed: true, reason: error.localizedDescription)
        }
    }

    /// Inputs that can be game audio. On a Mac this leaves out the built-in
    /// microphone, which would play the room through the speakers and feed back.
    var gameAudioSources: [AudioSource] {
        #if os(macOS)
        return audioSources.filter { !$0.isBuiltIn }
        #else
        return audioSources
        #endif
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
    private func explainMissingAudio(failed: Bool, reason: String? = nil) {
        if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
            #if os(iOS)
            let text = "Your iPad isn't letting PortPlay use the microphone, and the dongle's sound arrives as one. Open Settings, find PortPlay, and turn on Microphone. Then reopen the app."
            #else
            let text = "Your Mac isn't letting PortPlay use the microphone, and the dongle's sound arrives as one. Open System Settings, go to Privacy & Security, then Microphone, and turn on PortPlay. Then reopen the app."
            #endif
            showTip("audio-blocked", "Game sound is blocked", text)
        } else if failed {
            let detail = reason.map { "\($0) " } ?? ""
            showTip("audio-busy", "Couldn't open the game sound", "\(detail)Another app may be using it. Close other apps that use the dongle, then unplug the dongle and plug it back in.")
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
        renderer?.configure(scaling: profile.scaling, filter: profile.filter, sharpen: profile.sharpen, lowLatency: prefs.lowLatency)
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

    func setSharpen(_ on: Bool, announce: Bool = false) {
        setProfileValue { $0.sharpen = on }
        if prefs.lowLatency && on {
            setLowLatency(false)
            toast("Low latency mode is off so Sharpen can run")
        } else if announce {
            toast(on ? "Sharpen on" : "Sharpen off", duration: 1.5)
        }
        applyRenderer()
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
            toast(on ? "Low latency mode on. Filters, Sharpen and instant replay are paused." : "Low latency mode off")
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
        if profile.sharpen && !prefs.lowLatency { parts.append("sharpen") }
        if replay != nil { parts.append("replay on") }
        values.mode = parts.joined(separator: ", ")

        if values != live.hud { live.hud = values }
    }

    // MARK: Check my setup

    private static let silentAudioAdvice = "Check that your console sends its sound over HDMI, not to a headset. Unplug any USB headset or Bluetooth adapter from the console, and check that the game isn't muted."

    private static let hdcpAdvice = "PlayStation consoles block capture unless HDCP is off. On a PS5, go to Settings, System, HDMI and turn off Enable HDCP. On a PS4, it's Settings, System, Enable HDCP."

    func openCheckup() {
        setSettings(false)
        withAnimation(.easeOut(duration: 0.2)) { checkupOpen = true }
        runCheckup()
    }

    func closeCheckup() {
        checkupToken = UUID()
        checkupRunning = false
        withAnimation(.easeOut(duration: 0.2)) { checkupOpen = false }
    }

    /// Watches the picture and sound for four seconds, then lists anything that needs fixing.
    func runCheckup() {
        let token = UUID()
        checkupToken = token
        checkupRunning = true
        checkupSummary = "Watching the picture and sound for a few seconds."
        checks = ["Capture dongle", "Picture", "USB connection", "Game sound", "Performance"].map {
            SetupCheck(id: $0, status: .pending, title: $0)
        }

        Task { @MainActor in
            let started = CACurrentMediaTime()
            let droppedBefore = hub.dropped
            var fpsSamples: [Int] = []
            var dark = 0
            var samples = 0
            for _ in 0..<8 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard checkupToken == token else { return }
                guard isRunning else { continue }
                samples += 1
                fpsSamples.append(hub.framesPerSecond)
                if Self.isBlack(hub.latest) { dark += 1 }
            }
            let heardSound = (audio.lastSoundTime ?? 0) > started
            let results = collectChecks(
                fpsSamples: fpsSamples,
                dark: dark,
                samples: samples,
                heardSound: heardSound,
                dropped: hub.dropped - droppedBefore
            )
            guard checkupToken == token else { return }

            checks = results
            let problems = results.filter { $0.status == .bad || $0.status == .warn }.count
            switch problems {
            case 0: checkupSummary = "Everything looks good."
            case 1: checkupSummary = "One thing to look at."
            default: checkupSummary = "\(problems) things to look at, starting with the first."
            }
            checkupRunning = false
        }
    }

    private func collectChecks(fpsSamples: [Int], dark: Int, samples: Int, heardSound: Bool, dropped: Int) -> [SetupCheck] {
        var checks: [SetupCheck] = []

        // Capture dongle
        guard isRunning else {
            if screen == .denied {
                checks.append(SetupCheck(id: "dongle", status: .bad, title: "Camera access is off", text: Self.isMac
                    ? "Your dongle counts as a camera. Open System Settings, go to Privacy & Security, then Camera, and turn on PortPlay. Then reopen the app."
                    : "Your dongle counts as a camera. Open Settings, find PortPlay, and turn on Camera."))
            } else if case .interrupted(let reason) = screen {
                checks.append(SetupCheck(id: "dongle", status: .warn, title: "Video is paused", text: reason))
            } else if devices.isEmpty {
                checks.append(SetupCheck(id: "dongle", status: .bad, title: "No capture dongle found", text: Self.isMac
                    ? "Plug the dongle into a USB port on this Mac. If it's already plugged in, unplug it, wait a few seconds and plug it back in, or try another port."
                    : "Plug the dongle into the iPad's USB-C port, directly or through an adapter. If it's already plugged in, unplug it, wait a few seconds and plug it back in."))
            } else {
                checks.append(SetupCheck(id: "dongle", status: .warn, title: "Dongle found but not connected", text: "Choose it under Device in settings. If it still won't connect, close other apps that use the camera, like OBS, Zoom or FaceTime."))
            }
            return checks
        }
        checks.append(SetupCheck(id: "dongle", status: .good, title: "Capture dongle", text: "Connected to \(currentDevice?.localizedName ?? "your dongle")."))

        // Picture
        let fps = fpsSamples.isEmpty ? 0 : Int((Double(fpsSamples.reduce(0, +)) / Double(fpsSamples.count)).rounded())
        let live = fps > 0 && dark < samples
        if fps == 0 {
            checks.append(SetupCheck(id: "picture", status: .bad, title: "No picture from the console", text: "Turn the console on and wake it with its controller. Check that the HDMI cable goes from the console into the dongle. " + Self.hdcpAdvice))
        } else if !live {
            checks.append(SetupCheck(id: "picture", status: .warn, title: "The picture is black", text: "If the console is on, it may be blocking capture. " + Self.hdcpAdvice + " Also set the console's video output to 1080p or lower."))
        } else {
            checks.append(SetupCheck(id: "picture", status: .good, title: "Picture", text: "\(Resolutions.label(runningResolution)) at \(fps) fps."))
        }

        // USB connection
        let target = mode?.fps ?? 0
        if profile.framerate >= 50, caps.maxFps.isFinite, caps.maxFps < 49 {
            checks.append(SetupCheck(id: "usb", status: .warn, title: "Your dongle tops out at \(Int(caps.maxFps.rounded())) fps", text: Self.isMac
                ? "This usually means a USB 2 cable, hub or adapter. Plug the dongle straight into the Mac, or use a USB 3 cable or hub. If it already is, the dongle may be a USB 2 model."
                : "This usually means a USB 2 hub or adapter. Plug the dongle straight into the iPad. If it already is, the dongle may be a USB 2 model."))
        } else if live, target >= 25, Double(fps) < target * 0.75 {
            checks.append(SetupCheck(id: "usb", status: .warn, title: "Running at \(fps) fps instead of \(Int(target.rounded()))", text: "Plug the dongle straight into the \(Self.isMac ? "Mac" : "iPad"), set your console's video output to 1080p, or pick a lower resolution in settings."))
        } else if live {
            checks.append(SetupCheck(id: "usb", status: .good, title: "USB connection", text: "Fast enough for full speed."))
        }

        // Game sound
        switch audioProblem {
        case .off?:
            checks.append(SetupCheck(id: "sound", status: .info, title: "Game sound is off", text: "Game audio is set to None in settings."))
        case .blocked?:
            checks.append(SetupCheck(id: "sound", status: .bad, title: "Game sound is blocked", text: Self.isMac
                ? "The dongle's sound counts as a microphone. Open System Settings, go to Privacy & Security, then Microphone, and turn on PortPlay. Then reopen the app."
                : "The dongle's sound counts as a microphone. Open Settings, find PortPlay, and turn on Microphone. Then reopen the app."))
        case .failed(let reason)?:
            checks.append(SetupCheck(id: "sound", status: .bad, title: "Couldn't open the game sound", text: "\(reason) Close other apps that use the dongle, then unplug it and plug it back in."))
        case .missing?, nil:
            if !gameAudioRunning {
                checks.append(SetupCheck(id: "sound", status: .bad, title: "Couldn't find the game sound", text: Self.isMac
                    ? "Choose your dongle under Game audio in settings. If it isn't listed, unplug the dongle and plug it back in."
                    : "Unplug the dongle and plug it back in, or choose it under Game audio in settings."))
            } else if live && !heardSound {
                checks.append(SetupCheck(id: "sound", status: .warn, title: "No sound from the console", text: Self.silentAudioAdvice))
            } else if prefs.muted || prefs.volume <= 0.001 {
                checks.append(SetupCheck(id: "sound", status: .warn, title: "PortPlay is muted", text: Self.isMac ? "Press M or raise the volume." : "Turn the volume up in the control bar."))
            } else {
                checks.append(SetupCheck(id: "sound", status: .good, title: "Game sound", text: live ? "Sound is coming through." : "Ready."))
            }
        }

        // Performance, only meaningful with a live picture
        if live {
            if Double(dropped) > max(8, Double(fps) * 0.4) {
                checks.append(SetupCheck(id: "performance", status: .warn, title: "Frames are being dropped", text: "PortPlay is falling behind drawing the picture. Turn off filters, Sharpen and instant replay, or try low latency mode."))
            } else {
                checks.append(SetupCheck(id: "performance", status: .good, title: "Performance", text: "Keeping up with the console."))
            }
        }

        return checks
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

        // A picture but no sound for a while usually means the console sends its
        // sound somewhere else, like a USB headset adapter
        if gameAudioRunning, let lastSound = audio.lastSoundTime, CACurrentMediaTime() - lastSound >= 20 {
            showTip("silent-audio", "No sound from your console", Self.silentAudioAdvice + " Check my setup in settings can help too.")
        }

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

    // MARK: Clock

    /// The clock only shows while full screen, which on iPad is always.
    var clockShowing: Bool { prefs.clock && isFullScreen }

    func setClock(_ on: Bool, announce: Bool = false) {
        prefs.clock = on
        savePrefs()
        if announce {
            toast(on ? (isFullScreen ? "Clock on" : "Clock on. It shows in full screen.") : "Clock off", duration: 1.5)
        }
    }

    func setClockCorner(_ corner: ClockCorner) {
        prefs.clockCorner = corner
        savePrefs()
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
        mainWindow?.toggleFullScreen(nil)
        #endif
    }

    #if os(macOS)
    private func observeFullScreen() {
        let center = NotificationCenter.default
        for (name, value) in [
            (NSWindow.didEnterFullScreenNotification, true),
            (NSWindow.didExitFullScreenNotification, false),
        ] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let window = note.object as? NSWindow, !(window is NSPanel) else { return }
                Task { @MainActor in self?.isFullScreen = value }
            })
        }
        // The window can come back full screen when the app reopens
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isFullScreen = self.mainWindow?.styleMask.contains(.fullScreen) ?? false
        }
    }

    /// The PortPlay window, never the floating mini player.
    private var mainWindow: NSWindow? {
        if let key = NSApplication.shared.keyWindow, !(key is NSPanel) { return key }
        return NSApplication.shared.windows.first { $0.isVisible && !($0 is NSPanel) }
    }
    #endif

    /// Escape closes whatever is open on top, then leaves full screen.
    func handleEscape() {
        if checkupOpen {
            closeCheckup()
        } else if settingsOpen {
            setSettings(false)
        } else {
            #if os(macOS)
            if let window = mainWindow, window.styleMask.contains(.fullScreen) {
                window.toggleFullScreen(nil)
            }
            #endif
        }
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