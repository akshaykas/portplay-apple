import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var flash = 0.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let renderer = model.renderer {
                VideoSurface(session: model.capture.session, renderer: renderer, pip: model.pip)
                    .ignoresSafeArea()
            }

            // The picture itself. Taps and double clicks here never delay the buttons,
            // since the controls sit on top as separate views.
            stageGestures

            ZStack {
                if model.screen != .running {
                    StatusOverlay(screen: model.screen)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: model.screen)

            ZStack {
                if model.noSignal && model.isRunning {
                    NoSignalCard()
                }
            }
            .animation(.easeInOut(duration: 0.6), value: model.noSignal)

            // Screenshot flash
            Color.white
                .opacity(flash)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            // Recording time and troubleshooting tips, top left
            VStack(alignment: .leading, spacing: 12) {
                if model.isRecording {
                    RecordingIndicator(live: model.live)
                }
                if let tip = model.tip {
                    TipCard(tip: tip)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            // Stats, a small box in the top right like the Windows version
            if model.prefs.stats {
                HUDView(live: model.live)
                    .padding(14)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            }

            // Toasts above the control bar
            VStack(spacing: 14) {
                Spacer(minLength: 0)
                ToastStack()
                if model.controlsVisible {
                    ControlBar()
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 18)

            if model.settingsOpen {
                SettingsPanel()
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing))
            }

            KeyboardShortcuts()
        }
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { model.wake() }
        }
        .frame(minWidth: 480, minHeight: 270)
        #else
        .statusBarHidden()
        .persistentSystemOverlays(model.isRunning ? .hidden : .automatic)
        #endif
        .foregroundStyle(Theme.text)
        .preferredColorScheme(.dark)
        .onChange(of: model.flashToken) { _, _ in
            flash = 0.55
            withAnimation(.easeOut(duration: 0.45)) { flash = 0 }
        }
        .task { await model.launch() }
        // portplay://open from the website just brings PortPlay to the front
        .onOpenURL { _ in model.wake() }
    }

    private var stageGestures: some View {
        Color.clear
            .contentShape(Rectangle())
            .ignoresSafeArea()
            #if os(macOS)
            .onTapGesture(count: 2) { model.toggleFullscreen() }
            #else
            .onTapGesture { model.tapStage() }
            #endif
    }
}

/// Keyboard shortcuts from the Windows version, as invisible buttons.
/// They pause while typing a profile name.
struct KeyboardShortcuts: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Group {
                key("c") { model.takeScreenshot() }
                key("r") { model.toggleRecording() }
                key("v") { model.saveReplay() }
                key("s") { model.cycleScaling() }
                key("e") { model.cycleFilter() }
                key("m") { model.toggleMute() }
                key("g") { model.setLowLatency(!model.prefs.lowLatency, announce: true) }
                key("l") { model.setStats(!model.prefs.stats) }
                key("p") { model.togglePiP() }
                key("o") { model.toggleSettings() }
                #if os(macOS)
                key("f") { model.toggleFullscreen() }
                #endif
            }
            .disabled(model.isTypingName)

            Button("") { model.setSettings(false) }
                .keyboardShortcut(.escape, modifiers: [])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func key(_ character: Character, _ action: @escaping @MainActor () -> Void) -> some View {
        Button("") {
            model.wake()
            action()
        }
        .keyboardShortcut(KeyEquivalent(character), modifiers: [])
    }
}
