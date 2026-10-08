import AVFoundation
import QuartzCore

#if os(macOS)
import AudioToolbox
import CoreAudio
#endif

/// A sound input PortPlay can play: usually the dongle's own audio.
struct AudioSource: Identifiable, Hashable {
    let id: String
    let name: String
    /// USB vendor and product IDs when macOS reports them, for pairing with the video.
    let modelID: String
    let isUSB: Bool
}

enum AudioError: LocalizedError {
    case notFound
    case noSignal
    case couldNotSelect

    var errorDescription: String? {
        switch self {
        case .notFound: return "That audio input isn't connected."
        case .noSignal: return "The audio input isn't sending anything."
        case .couldNotSelect: return "The audio input couldn't be opened."
        }
    }
}

/// Game sound from the dongle to the speakers, with audio sync and volume up to 150%.
/// Recordings get the sound with the sync delay applied, before volume and mute,
/// like the Windows version.
///
/// * iPad: one AVAudioEngine, with the USB input as the session's input.
/// * Mac: one engine reads the dongle and another plays to the speakers, joined by
///   a small ring buffer, since the two devices run on separate clocks.
final class GameAudio: @unchecked Sendable {
    /// Recording feed, called on an audio thread. The time already includes the sync delay.
    var onBuffer: ((AVAudioPCMBuffer, CMTime) -> Void)?

    private let lock = NSLock()
    private var delayMs = 0
    private var volume = 1.0
    private var muted = false
    private(set) var format: AVAudioFormat?
    private(set) var isRunning = false

    private var delayUnit: AVAudioUnitDelay?
    private var gainUnit: AVAudioUnitEQ?

    #if os(iOS)
    private var engine: AVAudioEngine?
    #else
    private var inputEngine: AVAudioEngine?
    private var outputEngine: AVAudioEngine?
    private var ring: AudioRing?
    private var mic: MicMixer?
    #endif

    // MARK: Sources

    static func availableSources() -> [AudioSource] {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        return (session.availableInputs ?? [])
            .filter { $0.portType == .usbAudio }
            .map { AudioSource(id: $0.uid, name: $0.portName, modelID: "", isUSB: true) }
        #else
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )
        var seen = Set<String>()
        return discovery.devices.compactMap { device in
            guard seen.insert(device.uniqueID).inserted else { return nil }
            return AudioSource(
                id: device.uniqueID,
                name: device.localizedName,
                modelID: device.modelID,
                isUSB: UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeUSB
            )
        }
        #endif
    }

    // MARK: Settings

    func setVolume(_ volume: Double, muted: Bool) {
        lock.withLock {
            self.volume = volume
            self.muted = muted
        }
        applyGain()
    }

    func setDelay(ms: Int) {
        lock.withLock { delayMs = ms }
        delayUnit?.delayTime = Double(ms) / 1000
    }

    private func applyGain() {
        let (volume, muted) = lock.withLock { (self.volume, self.muted) }
        // Gain in decibels: 0 is the original level, +3.5 is about 150%
        let db = muted || volume <= 0.001 ? -96 : 20 * log10(volume)
        gainUnit?.globalGain = Float(min(max(db, -96), 24))
    }

    private func makeNodes(sampleRate: Double) -> (AVAudioUnitDelay, AVAudioUnitEQ) {
        let delay = AVAudioUnitDelay()
        delay.wetDryMix = 100
        delay.feedback = 0
        delay.lowPassCutoff = Float(sampleRate / 2)
        delay.delayTime = Double(lock.withLock { delayMs }) / 1000
        let gain = AVAudioUnitEQ(numberOfBands: 0)
        delayUnit = delay
        gainUnit = gain
        applyGain()
        return (delay, gain)
    }

    // MARK: Recording feed

    private func deliver(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) {
        guard let onBuffer else { return }
        let captured: Double
        if time.isHostTimeValid {
            captured = AVAudioTime.seconds(forHostTime: time.hostTime)
        } else {
            captured = CACurrentMediaTime() - Double(buffer.frameLength) / buffer.format.sampleRate
        }
        let synced = captured + Double(lock.withLock { delayMs }) / 1000
        var output = buffer
        #if os(macOS)
        if let mic = lock.withLock({ self.mic }), let copy = MediaBuffers.copy(buffer) {
            mic.mix(into: copy)
            output = copy
        }
        #endif
        onBuffer(output, CMTime(seconds: synced, preferredTimescale: 1_000_000_000))
    }

    // MARK: Delay readout for stats

    /// Sound delay from input to speakers, plus any audio sync, in milliseconds.
    var latencyMs: Double? {
        guard isRunning else { return nil }
        let sync = Double(lock.withLock { delayMs })
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        return (session.inputLatency + session.outputLatency + session.ioBufferDuration) * 1000 + sync
        #else
        let input = inputEngine?.inputNode.presentationLatency ?? 0
        let output = outputEngine?.outputNode.presentationLatency ?? 0
        let cushion = ring.map { _ in 0.02 } ?? 0
        return (input + output + cushion) * 1000 + sync
        #endif
    }

    // MARK: Start and stop

    func stop() {
        #if os(iOS)
        if let engine {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        engine = nil
        #else
        if let inputEngine {
            inputEngine.inputNode.removeTap(onBus: 0)
            inputEngine.stop()
        }
        outputEngine?.stop()
        let oldMic = lock.withLock { () -> MicMixer? in
            let current = mic
            mic = nil
            return current
        }
        oldMic?.stop()
        inputEngine = nil
        outputEngine = nil
        ring = nil
        #endif
        delayUnit = nil
        gainUnit = nil
        format = nil
        isRunning = false
    }

    #if os(iOS)
    func start(_ source: AudioSource) throws {
        stop()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothA2DP])
        guard let port = session.availableInputs?.first(where: { $0.uid == source.id }) else {
            throw AudioError.notFound
        }
        try session.setPreferredInput(port)
        try? session.setPreferredIOBufferDuration(0.005)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: min(hardware.channelCount, 2))
        else { throw AudioError.noSignal }

        let (delay, gain) = makeNodes(sampleRate: format.sampleRate)
        engine.attach(delay)
        engine.attach(gain)
        engine.connect(input, to: delay, format: format)
        engine.connect(delay, to: gain, format: format)
        engine.connect(gain, to: engine.mainMixerNode, format: format)
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, time in
            self?.deliver(buffer, at: time)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
        self.engine = engine
        self.format = format
        isRunning = true
    }

    #else
    func start(_ source: AudioSource, mic micSource: AudioSource?, micLevel: Double) throws {
        stop()
        guard let deviceID = Self.deviceID(forUID: source.id) else { throw AudioError.notFound }

        // Engine one: the dongle's sound into the ring
        let inputEngine = AVAudioEngine()
        let input = inputEngine.inputNode
        guard let unit = input.audioUnit else { throw AudioError.couldNotSelect }
        var device = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else { throw AudioError.couldNotSelect }

        let hardware = input.inputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: min(hardware.channelCount, 2))
        else { throw AudioError.noSignal }

        let ring = AudioRing(
            channels: Int(format.channelCount),
            capacity: Int(format.sampleRate),
            target: Int(format.sampleRate * 0.02)
        )
        let sink = AVAudioSinkNode { _, frameCount, bufferList in
            ring.write(UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList)), frames: Int(frameCount))
            return noErr
        }
        inputEngine.attach(sink)
        inputEngine.connect(input, to: sink, format: format)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
            self?.deliver(buffer, at: time)
        }

        // Engine two: the ring to the speakers, through audio sync and volume
        let outputEngine = AVAudioEngine()
        let player = AVAudioSourceNode(format: format) { isSilence, _, frameCount, bufferList in
            let played = ring.readForPlayback(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(frameCount))
            if !played { isSilence.pointee = true }
            return noErr
        }
        let (delay, gain) = makeNodes(sampleRate: format.sampleRate)
        outputEngine.attach(player)
        outputEngine.attach(delay)
        outputEngine.attach(gain)
        outputEngine.connect(player, to: delay, format: format)
        outputEngine.connect(delay, to: gain, format: format)
        outputEngine.connect(gain, to: outputEngine.mainMixerNode, format: format)

        do {
            inputEngine.prepare()
            try inputEngine.start()
            outputEngine.prepare()
            try outputEngine.start()
        } catch {
            input.removeTap(onBus: 0)
            inputEngine.stop()
            outputEngine.stop()
            throw error
        }

        self.inputEngine = inputEngine
        self.outputEngine = outputEngine
        self.ring = ring
        self.format = format
        isRunning = true

        if let micSource {
            setMic(micSource, level: micLevel)
        }
    }

    /// The microphone only goes into recordings and replays. Returns false if it couldn't open.
    @discardableResult
    func setMic(_ source: AudioSource?, level: Double) -> Bool {
        let oldMic = lock.withLock { () -> MicMixer? in
            let current = mic
            mic = nil
            return current
        }
        oldMic?.stop()
        guard let source, let format, isRunning else { return source == nil }
        guard let newMic = MicMixer(source: source, targetFormat: format, level: level) else { return false }
        lock.withLock { mic = newMic }
        return true
    }

    func setMicLevel(_ level: Double) {
        lock.withLock { mic }?.level = Float(level)
    }

    /// Turns a CoreAudio device UID, which AVFoundation uses as the uniqueID, into a device ID.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafePointer(to: &cfUID) { pointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                pointer,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }
    #endif
}

#if os(macOS)
/// A microphone that only goes into recordings and replays, never to the speakers.
final class MicMixer: @unchecked Sendable {
    var level: Float

    private let engine = AVAudioEngine()
    private let ring: AudioRing
    private var converter: AVAudioConverter?

    init?(source: AudioSource, targetFormat: AVAudioFormat, level: Double) {
        self.level = Float(level)
        ring = AudioRing(
            channels: Int(targetFormat.channelCount),
            capacity: Int(targetFormat.sampleRate),
            target: 0
        )

        guard let deviceID = GameAudio.deviceID(forUID: source.id),
              let unit = engine.inputNode.audioUnit
        else { return nil }
        var device = deviceID
        guard AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &device,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { return nil }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let converter = AVAudioConverter(from: inputFormat, to: targetFormat)
        else { return nil }
        if inputFormat.channelCount == 1, targetFormat.channelCount == 2 {
            converter.channelMap = [0, 0]
        }
        self.converter = converter

        let ring = self.ring
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { buffer, _ in
            let ratio = targetFormat.sampleRate / inputFormat.sampleRate
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 64)
            guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var fed = false
            var error: NSError?
            _ = converter.convert(to: converted, error: &error) { _, status in
                if fed {
                    status.pointee = .noDataNow
                    return nil
                }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard error == nil, converted.frameLength > 0 else { return }
            ring.write(UnsafeMutableAudioBufferListPointer(converted.mutableAudioBufferList), frames: Int(converted.frameLength))
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            return nil
        }
    }

    func mix(into buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        ring.mixAvailable(
            into: channels,
            channelCount: Int(buffer.format.channelCount),
            frames: Int(buffer.frameLength),
            gain: level
        )
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}
#endif
