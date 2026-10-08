import AVFoundation
import SwiftUI

/// The settings sheet on the right, with the same sections as the Windows version.
struct SettingsPanel: View {
    @EnvironmentObject private var model: AppModel
    @State private var newProfileName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    captureSection
                    profilesSection
                    audioSection
                    recordingSection
                    controllerSection
                    keyboardSection
                }
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: 360, maxHeight: .infinity)
        .panel(solid: true)
        .onHover { model.pointerOnControls = $0 }
        .onChange(of: nameFocused) { _, focused in
            model.isTypingName = focused
        }
        .onDisappear { model.isTypingName = false }
    }

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
            Spacer()
            Button {
                model.setSettings(false)
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(IconButtonStyle())
            .accessibilityLabel("Close settings")
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 12)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }

    // MARK: Capture

    private var captureSection: some View {
        SettingsSection("Capture") {
            Field("Device") {
                if model.devices.isEmpty {
                    Text("No capture devices found")
                        .hint()
                } else {
                    ChoiceMenu(
                        title: model.currentDevice?.localizedName ?? "Choose a device",
                        options: model.devices.map { ($0.uniqueID, $0.localizedName, true) },
                        selected: model.currentDevice?.uniqueID
                    ) { id in
                        if let device = model.devices.first(where: { $0.uniqueID == id }) {
                            model.selectDevice(device)
                        }
                    }
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Field("Resolution") {
                    ChoiceMenu(
                        title: Resolutions.label(model.isRunning ? model.runningResolution : model.profile.resolution),
                        options: Resolutions.all.map { ($0.value, $0.label, model.isResolutionSupported($0.value)) },
                        selected: model.isRunning ? model.runningResolution : model.profile.resolution
                    ) { model.setResolution($0) }
                }
                Field("Frame rate") {
                    ChoiceMenu(
                        title: "\(model.profile.framerate) fps",
                        options: FrameRates.all.map { ("\($0)", "\($0) fps", model.isFrameRateSupported($0)) },
                        selected: "\(model.profile.framerate)"
                    ) { value in
                        if let fps = Int(value) { model.setFrameRate(fps) }
                    }
                }
            }
        }
    }

    // MARK: Profiles

    private var profilesSection: some View {
        SettingsSection("Profiles") {
            Text("A profile remembers resolution, frame rate, scaling, filter and audio sync. The last profile you used with each capture device comes back automatically.")
                .hint()
            HStack(spacing: 8) {
                TextField("New profile name, like Switch", text: $newProfileName)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .onSubmit(saveProfile)
                    .padding(.horizontal, 10)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                    .onChange(of: newProfileName) { _, value in
                        if value.count > 24 { newProfileName = String(value.prefix(24)) }
                    }
                Button("Save as new", action: saveProfile)
                    .buttonStyle(PillButtonStyle(primary: true, small: true))
                    .fixedSize()
            }
            Button("Delete this profile") { model.deleteProfile() }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.muted)
                .disabled(model.profiles.count <= 1)
                .opacity(model.profiles.count <= 1 ? 0.4 : 1)
        }
    }

    private func saveProfile() {
        if model.saveProfile(named: newProfileName) {
            newProfileName = ""
            nameFocused = false
        }
    }

    // MARK: Audio

    private var audioSection: some View {
        SettingsSection("Audio") {
            Field("Game audio") {
                if model.currentDevice == nil {
                    ChoiceMenu(title: "Connect your dongle first", options: [], selected: nil) { _ in }
                        .disabled(true)
                } else {
                    let automatic = model.autoAudio.map { "Automatic (\($0.name))" } ?? "Automatic (not found)"
                    let sources: [(String, String, Bool)] = model.audioSources.map { ($0.id, $0.name, true) }
                    let choices: [(String, String, Bool)] = [("auto", automatic, true), ("off", "None", true)] + sources
                    let selected = model.gameAudioSelection ?? "auto"
                    ChoiceMenu(
                        title: choices.first { $0.0 == selected }?.1 ?? automatic,
                        options: choices,
                        selected: selected
                    ) { value in
                        model.setGameAudio(value == "auto" ? nil : value)
                    }
                }
            }
            Text("The sound from your console. Automatic usually finds it. If you hear nothing, pick your dongle here.")
                .hint()

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Audio sync")
                    Spacer()
                    Text("\(model.profile.audioDelay) ms")
                        .foregroundStyle(Theme.muted)
                        .monospacedDigit()
                        .fontWeight(.medium)
                }
                .font(.system(size: 13, weight: .semibold))
                Slider(
                    value: Binding(
                        get: { Double(model.profile.audioDelay) },
                        set: { model.setAudioDelay(Int($0.rounded())) }
                    ),
                    in: 0...300,
                    step: 5
                )
                .tint(Theme.accent)
            }
            Text("If voices land before lips move, slide this right until they match.")
                .hint()

            #if os(macOS)
            Field("Microphone in recordings") {
                let mics: [(String, String, Bool)] = model.micSources.map { ($0.id, $0.name, true) }
                let options: [(String, String, Bool)] = [("", "Off", true)] + mics
                ChoiceMenu(
                    title: options.first { $0.0 == model.prefs.micID }?.1 ?? "Off",
                    options: options,
                    selected: model.prefs.micID
                ) { model.setMic($0) }
            }
            if !model.prefs.micID.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Microphone level")
                        .font(.system(size: 13, weight: .semibold))
                    Slider(
                        value: Binding(get: { model.prefs.micLevel }, set: { model.setMicLevel($0) }),
                        in: 0...2,
                        step: 0.05
                    )
                    .tint(Theme.accent)
                }
            }
            Text("Your microphone is only added to recordings and replays. You won't hear it through your speakers.")
                .hint()
            #endif
        }
    }

    // MARK: Recording

    private var recordingSection: some View {
        SettingsSection("Recording") {
            SwitchRow(
                title: "Instant replay",
                hint: AppModel.isMac
                    ? "Keeps the last 30 seconds ready to save with V. Uses some extra processing power."
                    : "Keeps the last 30 seconds ready to save with the replay button. Uses some extra battery.",
                isOn: Binding(get: { model.prefs.replay }, set: { model.setReplay($0) })
            )
            SwitchRow(
                title: "Low latency mode",
                hint: "Pauses filters and instant replay so nothing sits between the dongle and your screen.",
                isOn: Binding(get: { model.prefs.lowLatency }, set: { model.setLowLatency($0, announce: true) })
            )
            Text(AppModel.isMac
                ? "Screenshots go to Pictures and recordings go to Movies, each in a PortPlay folder."
                : "Screenshots and recordings are saved to Photos. Screenshots are copied too, so you can paste them anywhere.")
                .hint()
        }
    }

    // MARK: Controller

    private var controllerSection: some View {
        SettingsSection("Controller", icon: "gamecontroller") {
            Text(model.controllerStatus).hint()
            Text("Hold Select (View, Share or Create) and press:").hint()
            KeyList(rows: Self.controllerRows)
            Text(AppModel.isMac
                ? "This means a controller connected to this Mac, not the one paired with your console."
                : "This means a controller connected to this iPad, not the one paired with your console.")
                .hint()
        }
    }

    // MARK: Keyboard

    private var keyboardSection: some View {
        SettingsSection(AppModel.isMac ? "Keyboard shortcuts" : "Keyboard shortcuts with a keyboard") {
            KeyList(rows: Self.keyboardRows)
        }
    }
}

// MARK: - Shortcut lists

private extension SettingsPanel {
    static var controllerRows: [(String, String)] {
        var rows: [(String, String)] = [
            ("A", "Screenshot"),
            ("B", "Start or stop recording"),
            ("X", "Save instant replay"),
        ]
        if AppModel.isMac {
            rows.append(("Y", "Full screen"))
        }
        rows.append(("LB", "Next scaling mode"))
        rows.append(("RB", "Next filter"))
        rows.append(("Start", "Stats"))
        return rows
    }

    static var keyboardRows: [(String, String)] {
        var rows: [(String, String)] = []
        if AppModel.isMac {
            rows.append(("F", "Full screen, or double click"))
        }
        let shared: [(String, String)] = [
            ("C", "Screenshot"),
            ("R", "Start or stop recording"),
            ("V", "Save instant replay"),
            ("S", "Next scaling mode"),
            ("E", "Next filter"),
            ("M", "Mute"),
            ("G", "Low latency mode"),
            ("L", "Stats"),
            ("P", "Picture in picture"),
            ("O", "Settings"),
        ]
        rows.append(contentsOf: shared)
        return rows
    }
}

// MARK: - Building blocks

private struct SettingsSection<Content: View>: View {
    let title: String
    var icon: String?
    @ViewBuilder let content: Content

    init(_ title: String, icon: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 13))
                }
                Text(title.uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1)
            }
            .foregroundStyle(Theme.muted)
            content
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.border).frame(height: 1)
        }
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A dropdown like the Windows version's selects, where options the dongle can't do are greyed out.
struct ChoiceMenu: View {
    let title: String
    let options: [(String, String, Bool)]
    let selected: String?
    let choose: (String) -> Void

    var body: some View {
        Menu {
            ForEach(options, id: \.0) { option in
                Button {
                    choose(option.0)
                } label: {
                    if option.0 == selected {
                        Label(option.1, systemImage: "checkmark")
                    } else {
                        Text(option.1)
                    }
                }
                .disabled(!option.2)
            }
        } label: {
            HStack {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 6)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }
}

private struct SwitchRow: View {
    let title: String
    let hint: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .bold))
                Text(hint).hint()
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.accentStrong)
    }
}

private struct KeyList: View {
    let rows: [(String, String)]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 7) {
            ForEach(rows, id: \.0) { row in
                GridRow {
                    Text(row.0)
                        .font(.system(size: 12, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .frame(minWidth: 26)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.raised))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.borderStrong, lineWidth: 1))
                    Text(row.1)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }
}

extension Text {
    /// Small grey explanatory text, like `.hint` in the stylesheet.
    func hint() -> some View {
        self
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.muted)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}
