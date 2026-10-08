#if os(iOS)
import AVFoundation

/// Plays the dongle's USB audio input straight to the iPad speakers or headphones.
///
/// It only starts when a USB audio input is present. Starting with the built-in
/// microphone instead would feed the speakers back into the mic and squeal.
final class AudioPassthrough {
    private let engine = AVAudioEngine()
    private var isConnected = false

    func setMuted(_ muted: Bool) {
        engine.mainMixerNode.outputVolume = muted ? 0 : 1
    }

    /// Returns true when USB audio is playing.
    @discardableResult
    func restart(muted: Bool) -> Bool {
        stop()

        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .default,
                options: [.defaultToSpeaker, .allowBluetoothA2DP]
            )

            guard let usb = session.availableInputs?.first(where: { $0.portType == .usbAudio }) else {
                return false
            }

            try session.setPreferredInput(usb)
            try? session.setPreferredIOBufferDuration(0.005)
            try session.setActive(true)

            let input = engine.inputNode
            let format = input.inputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                return false
            }

            engine.connect(input, to: engine.mainMixerNode, format: format)
            isConnected = true
            setMuted(muted)
            engine.prepare()
            try engine.start()
            return true
        } catch {
            stop()
            return false
        }
    }

    func stop() {
        if engine.isRunning {
            engine.stop()
        }
        if isConnected {
            engine.disconnectNodeOutput(engine.inputNode)
            isConnected = false
        }
    }
}
#endif
