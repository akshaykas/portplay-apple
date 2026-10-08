import AVFoundation
import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

struct ContentView: View {
    @EnvironmentObject private var capture: CaptureManager
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            PreviewView(session: capture.session, device: capture.activeDevice)
                .ignoresSafeArea()

            statusOverlay

            if showControls, capture.activeDevice != nil {
                controls
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { toggleControls() }
        #if os(macOS)
        .frame(minWidth: 640, minHeight: 360)
        .onContinuousHover { phase in
            // Moving the mouse brings the controls back, like a video player.
            if case .active = phase { revealControls() }
        }
        #else
        .statusBarHidden()
        .persistentSystemOverlays(capture.status == .running ? .hidden : .automatic)
        #endif
        .task { await capture.start() }
        .onChange(of: capture.status) { _, _ in scheduleHide() }
    }

    // MARK: Status screens

    @ViewBuilder
    private var statusOverlay: some View {
        switch capture.status {
        case .starting:
            ProgressView()
                .tint(.white)

        case .denied:
            message(icon: "video.slash", title: "Camera access is off", body: Copy.deniedBody) {
                Button("Open Settings") { openPrivacySettings() }
                    .buttonStyle(.borderedProminent)
            }

        case .waitingForDevice:
            message(icon: "cable.connector", title: "Connect your capture dongle", body: Copy.waitingBody) {
                EmptyView()
            }

        case .interrupted(let text):
            message(icon: "pause.circle", title: "Paused", body: text) {
                EmptyView()
            }

        case .failed(let text):
            message(icon: "exclamationmark.triangle", title: "Something went wrong", body: text) {
                Button("Try Again") { capture.retry() }
                    .buttonStyle(.borderedProminent)
            }

        case .running:
            EmptyView()
        }
    }

    private func message<Actions: View>(
        icon: String,
        title: String,
        body: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title2.weight(.semibold))
            Text(body)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .frame(maxWidth: 420)
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .padding()
    }

    private func openPrivacySettings() {
        #if os(iOS)
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        #else
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
            NSWorkspace.shared.open(url)
        }
        #endif
    }

    // MARK: Controls

    private var controls: some View {
        VStack {
            HStack(spacing: 20) {
                deviceMenu
                Spacer(minLength: 12)
                qualityMenu
                muteButton
            }
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.ultraThinMaterial, in: Capsule())
            .padding()

            Spacer()
        }
    }

    private var deviceMenu: some View {
        Menu {
            Section("Video") {
                ForEach(capture.devices, id: \.uniqueID) { device in
                    checkButton(device.localizedName, checked: device == capture.activeDevice) {
                        capture.select(device)
                    }
                }
            }
            #if os(macOS)
            Section("Audio") {
                checkButton("Automatic", checked: capture.audioChoice == .automatic) {
                    capture.selectAudio(.automatic)
                }
                ForEach(capture.audioSources, id: \.uniqueID) { source in
                    checkButton(source.localizedName, checked: capture.audioChoice == .device(source.uniqueID)) {
                        capture.selectAudio(.device(source.uniqueID))
                    }
                }
                checkButton("Off", checked: capture.audioChoice == .off) {
                    capture.selectAudio(.off)
                }
            }
            #endif
        } label: {
            Label(capture.activeDevice?.localizedName ?? "Device", systemImage: "rectangle.connected.to.line.below")
                .lineLimit(1)
        }
        .menuStyleForPlatform()
    }

    @ViewBuilder
    private var qualityMenu: some View {
        if !capture.modes.isEmpty {
            Menu {
                ForEach(capture.modes) { mode in
                    checkButton(mode.label, checked: mode == capture.activeMode) {
                        capture.select(mode)
                    }
                }
            } label: {
                Label(capture.activeMode?.label ?? "Quality", systemImage: "slider.horizontal.3")
            }
            .menuStyleForPlatform()
        }
    }

    private var muteButton: some View {
        Button {
            capture.isMuted.toggle()
        } label: {
            Image(systemName: muteIcon)
                .frame(width: 28)
        }
        .buttonStyle(.plain)
        .disabled(!capture.hasAudio)
        .accessibilityLabel(capture.isMuted ? "Unmute" : "Mute")
        #if os(macOS)
        .keyboardShortcut("m", modifiers: [])
        .help(capture.hasAudio ? "Mute (M)" : "No audio from the dongle")
        #endif
    }

    private func checkButton(_ title: String, checked: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if checked {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var muteIcon: String {
        if !capture.hasAudio { return "speaker.slash" }
        return capture.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
    }

    // MARK: Auto-hide

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
        if showControls { scheduleHide() }
    }

    private func revealControls() {
        if !showControls {
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        }
        scheduleHide()
    }

    /// Hides the controls a few seconds after video starts so nothing covers the game.
    private func scheduleHide() {
        hideTask?.cancel()
        guard capture.status == .running else {
            showControls = true
            return
        }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }
}

// MARK: - Platform copy and styling

private enum Copy {
    #if os(iOS)
    static let deniedBody = "PortPlay reads your capture dongle the same way apps read a camera. Turn on Camera for PortPlay in Settings."
    static let waitingBody = "Plug a USB HDMI capture dongle into your iPad's USB-C port, then connect your console's HDMI cable to it. On PlayStation, turn off HDCP in the console's settings."
    #else
    static let deniedBody = "PortPlay reads your capture dongle the same way apps read a camera. Turn on PortPlay under Privacy & Security, then Camera, in System Settings."
    static let waitingBody = "Plug a USB HDMI capture dongle into your Mac, then connect your console's HDMI cable to it. On PlayStation, turn off HDCP in the console's settings."
    #endif
}

private extension View {
    @ViewBuilder
    func menuStyleForPlatform() -> some View {
        #if os(macOS)
        self.menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
        #else
        self
        #endif
    }
}
