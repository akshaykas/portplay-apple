import SwiftUI

/// The floating bar at the bottom, laid out like the Windows version's:
/// profile, scaling, filter, volume, captures, then tools.
struct ControlBar: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                pictureControls
                actionControls
            }
            VStack(spacing: 6) {
                HStack(spacing: 10) { pictureControls }
                HStack(spacing: 10) { actionControls }
            }
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    profileMenu
                    scalingChoice
                }
                HStack(spacing: 10) {
                    filterChoice
                    volumeGroup
                }
                HStack(spacing: 10) {
                    captureGroup
                    toolsGroup
                }
            }
        }
        .padding(7)
        .panel()
        .onHover { model.pointerOnControls = $0 }
    }

    // MARK: Groups

    @ViewBuilder
    private var pictureControls: some View {
        profileMenu
        scalingChoice
        filterChoice
    }

    @ViewBuilder
    private var actionControls: some View {
        volumeGroup
        captureGroup
        toolsGroup
    }

    private var profileMenu: some View {
        Menu {
            Picker("Profile", selection: Binding(
                get: { model.activeProfileName },
                set: { model.switchProfile($0) }
            )) {
                ForEach(model.profiles) { item in
                    Text(item.name).tag(item.name)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Button("Manage profiles") { model.setSettings(true) }
        } label: {
            HStack(spacing: 8) {
                Text(model.activeProfileName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.muted)
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 14)
            .frame(height: 38)
            .frame(maxWidth: 150)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.raised))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Profile")
    }

    private var scalingChoice: some View {
        SegmentedChoice(
            options: ScaleMode.allCases,
            selection: model.profile.scaling,
            label: { $0.label },
            choose: { model.setScaling($0) }
        )
        .help(Shortcut.tip("Scaling", "S"))
    }

    private var filterChoice: some View {
        SegmentedChoice(
            options: RetroFilter.allCases,
            selection: model.profile.filter,
            dimmed: model.prefs.lowLatency,
            label: { $0.label },
            choose: { model.setFilter($0) }
        )
        .help(Shortcut.tip("Retro filter", "E"))
    }

    private var volumeGroup: some View {
        Group {
            HStack(spacing: 2) {
                Button {
                    model.toggleMute()
                } label: {
                    Image(systemName: model.prefs.muted ? "speaker.slash" : "speaker.wave.2")
                }
                .buttonStyle(IconButtonStyle(active: model.prefs.muted))
                .help(Shortcut.tip(model.prefs.muted ? "Unmute" : "Mute", "M"))
                .accessibilityLabel(model.prefs.muted ? "Unmute" : "Mute")

                Slider(
                    value: Binding(get: { model.prefs.volume }, set: { model.setVolume($0) }),
                    in: 0...1.5,
                    step: 0.05
                )
                .frame(width: 84)
                .tint(Theme.accent)
                .padding(.trailing, 6)
                .accessibilityLabel("Volume")
            }
        }
        .groupDivider()
    }

    private var captureGroup: some View {
        HStack(spacing: 2) {
            Button(action: { model.takeScreenshot() }) {
                Image(systemName: "camera")
            }
            .buttonStyle(IconButtonStyle())
            .help(Shortcut.tip("Screenshot", "C"))
            .accessibilityLabel("Screenshot")

            Button(action: { model.toggleRecording() }) {
                Image(systemName: model.isRecording ? "stop.circle" : "record.circle")
            }
            .buttonStyle(IconButtonStyle(active: model.isRecording, tint: Theme.danger))
            .help(Shortcut.tip(model.isRecording ? "Stop recording" : "Record", "R"))
            .accessibilityLabel(model.isRecording ? "Stop recording" : "Record")

            Button(action: { model.saveReplay() }) {
                Image(systemName: "gobackward.30")
                    .overlay(alignment: .topTrailing) {
                        if model.replayArmed {
                            Circle()
                                .fill(Theme.accent)
                                .frame(width: 6, height: 6)
                                .shadow(color: Theme.accent, radius: 3)
                                .offset(x: 7, y: -6)
                        }
                    }
            }
            .buttonStyle(IconButtonStyle(idleColor: model.replayArmed ? Theme.accent : Theme.text))
            .help(Shortcut.tip(model.prefs.replay ? "Save the last 30 seconds" : "Turn on instant replay", "V"))
            .accessibilityLabel("Save instant replay")
        }
        .groupDivider()
    }

    private var toolsGroup: some View {
        HStack(spacing: 2) {
            Button {
                model.setLowLatency(!model.prefs.lowLatency, announce: true)
            } label: {
                Image(systemName: model.prefs.lowLatency ? "bolt.fill" : "bolt")
            }
            .buttonStyle(IconButtonStyle(active: model.prefs.lowLatency))
            .help(Shortcut.tip("Low latency mode", "G"))
            .accessibilityLabel("Low latency mode")

            Button {
                model.setStats(!model.prefs.stats)
            } label: {
                Image(systemName: "waveform.path.ecg")
            }
            .buttonStyle(IconButtonStyle(active: model.prefs.stats))
            .help(Shortcut.tip("Delay and frame stats", "L"))
            .accessibilityLabel("Stats")

            if model.pip.isSupported {
                Button(action: { model.togglePiP() }) {
                    Image(systemName: model.pipActive ? "pip.exit" : "pip.enter")
                }
                .buttonStyle(IconButtonStyle(active: model.pipActive))
                .help(Shortcut.tip("Picture in picture", "P"))
                .accessibilityLabel("Picture in picture")
            }

            if AppModel.isMac {
                Button(action: { model.toggleFullscreen() }) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(IconButtonStyle())
                .help(Shortcut.tip("Full screen", "F"))
                .accessibilityLabel("Full screen")
            }

            Button(action: { model.toggleSettings() }) {
                Image(systemName: "slider.horizontal.3")
            }
            .buttonStyle(IconButtonStyle(active: model.settingsOpen))
            .help(Shortcut.tip("Settings", "O"))
            .accessibilityLabel("Settings")
        }
        .groupDivider()
    }
}

private extension View {
    /// The thin line between groups in the bar.
    func groupDivider() -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Theme.border)
                .frame(width: 1, height: 26)
            self
        }
    }
}

enum Shortcut {
    /// Tooltip text, with the keyboard shortcut on Mac.
    static func tip(_ text: String, _ key: String) -> String {
        AppModel.isMac ? "\(text) (\(key))" : text
    }
}
