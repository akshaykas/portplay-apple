import SwiftUI

#if os(iOS)
import UIKit
#else
import AppKit
#endif

// MARK: - Status screen

/// Shown whenever there's no live picture: looking, connecting, errors and setup help.
struct StatusOverlay: View {
    @EnvironmentObject private var model: AppModel
    let screen: AppModel.Screen

    var body: some View {
        ZStack {
            RadialGradient(
                colors: [Color(hex: 0x121A33), Theme.background],
                center: UnitPoint(x: 0.5, y: 0.3),
                startRadius: 0,
                endRadius: 700
            )
            .ignoresSafeArea()

            ScrollView {
                VStack(spacing: 10) {
                    Text(title)
                        .font(.system(size: 30, weight: .bold))
                        .multilineTextAlignment(.center)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 15))
                            .foregroundStyle(Theme.muted)
                            .multilineTextAlignment(.center)
                            .lineSpacing(3)
                            .frame(maxWidth: 520)
                    }
                    if showsSetup {
                        SetupSteps()
                            .padding(.top, 18)
                    }
                    actions
                        .padding(.top, 16)
                }
                .frame(maxWidth: 760)
                .padding(.horizontal, 24)
                .padding(.top, 60)
                .padding(.bottom, 130)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var title: String {
        switch screen {
        case .starting: return "Looking for your capture device"
        case .connecting: return "Connecting"
        case .denied: return "Camera access is turned off"
        case .noDevice: return "No capture device found"
        case .disconnected: return "Capture device disconnected"
        case .interrupted: return "Paused"
        case .failed(let title, _): return title
        case .running: return ""
        }
    }

    private var detail: String {
        switch screen {
        case .denied:
            #if os(iOS)
            return "Your iPad treats the HDMI dongle as a camera. Open Settings, find PortPlay, and turn on Camera and Microphone. Then reopen the app."
            #else
            return "Your Mac treats the HDMI dongle as a camera. Open System Settings, go to Privacy & Security, and turn on PortPlay under Camera and Microphone. Then reopen the app."
            #endif
        case .noDevice:
            return "Plug in your HDMI to USB dongle, or choose a device in settings."
        case .disconnected:
            return "Plug it back in to reconnect."
        case .interrupted(let message):
            return message
        case .failed(_, let detail):
            return detail
        default:
            return ""
        }
    }

    private var showsSetup: Bool {
        screen == .noDevice || screen == .disconnected
    }

    @ViewBuilder
    private var actions: some View {
        switch screen {
        case .denied:
            Button("Open Settings", action: openPrivacySettings)
                .buttonStyle(PillButtonStyle(primary: true))
        case .failed:
            Button("Try Again") { model.retry() }
                .buttonStyle(PillButtonStyle(primary: true))
        case .starting, .connecting:
            ProgressView()
                .tint(Theme.muted)
        default:
            EmptyView()
        }
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
}

/// Three setup steps, highlighted one at a time like the Windows version.
struct SetupSteps: View {
    private let steps: [(icon: String, title: String, text: String)] = [
        (
            "cable.connector",
            "Plug in the dongle",
            AppModel.isMac
                ? "It's a small stick with an HDMI port on one end and a USB plug on the other. Use a USB-C or USB 3 port, with an adapter if needed."
                : "It's a small stick with an HDMI port on one end and a USB plug on the other. Plug it into your iPad's USB-C port, with an adapter if needed."
        ),
        (
            "gamecontroller",
            "Connect your console",
            "Plug your console's HDMI cable into the dongle instead of your TV, then turn the console on."
        ),
        (
            AppModel.isMac ? "display" : "ipad.landscape",
            "Start playing",
            "PortPlay finds the dongle on its own and shows your game."
        ),
    ]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2.5)) { context in
            let focus = Int(context.date.timeIntervalSinceReferenceDate / 2.5) % 3
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) { cards(focus: focus) }
                VStack(spacing: 14) { cards(focus: focus) }
            }
            .animation(.easeInOut(duration: 0.4), value: focus)
        }
    }

    @ViewBuilder
    private func cards(focus: Int) -> some View {
        ForEach(steps.indices, id: \.self) { index in
            let step = steps[index]
            let lit = index == focus
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("\(index + 1)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.accentSoft))
                    Spacer()
                }
                Image(systemName: step.icon)
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(lit ? Theme.accent : Theme.muted)
                    .frame(maxWidth: .infinity)
                    .frame(height: 64)
                Text(step.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(step.text)
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(minWidth: 200, maxWidth: 240, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(lit ? Theme.accent.opacity(0.08) : Theme.raised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(lit ? Theme.accent.opacity(0.55) : Theme.border, lineWidth: 1)
            )
            .offset(y: lit ? -2 : 0)
        }
    }
}

// MARK: - No signal

/// The dongle is connected but the picture is black or frozen.
struct NoSignalCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Theme.background.opacity(0.88).ignoresSafeArea()
            VStack(spacing: 0) {
                pulse
                Text("Connected, waiting for a picture")
                    .font(.system(size: 22, weight: .bold))
                    .multilineTextAlignment(.center)
                    .padding(.top, 26)
                    .padding(.bottom, 8)
                Text("Your console may be off or asleep. Press the PS, Home or Xbox button on your controller to wake it.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                Text("Still nothing? Check that the HDMI cable goes from the console into the dongle, and that the console's video output is set to 1080p or lower. PlayStation consoles also need HDCP turned off.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .padding(.top, 10)
                Button("Check my setup") { model.openCheckup() }
                    .buttonStyle(PillButtonStyle(small: true))
                    .padding(.top, 16)
            }
            .frame(maxWidth: 440)
            .padding(24)
        }
        .transition(.opacity)
    }

    private var pulse: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                ForEach(0..<3, id: \.self) { ring in
                    let phase = (t + Double(ring)).truncatingRemainder(dividingBy: 3) / 3
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 1.5)
                        .scaleEffect(0.45 + 0.9 * phase)
                        .opacity(0.7 * (1 - phase))
                }
                Image(systemName: "tv")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(Theme.accent)
            }
            .frame(width: 96, height: 96)
        }
    }
}

// MARK: - Check my setup

struct CheckupView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ZStack {
            Color(red: 4 / 255, green: 5 / 255, blue: 8 / 255).opacity(0.62)
                .ignoresSafeArea()
                .onTapGesture { model.closeCheckup() }

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("Check my setup")
                        .font(.system(size: 19, weight: .bold))
                    Spacer()
                    Button {
                        model.closeCheckup()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(IconButtonStyle())
                    .accessibilityLabel("Close")
                }
                Text(model.checkupSummary)
                    .hint()
                    .padding(.top, 2)

                // Scrolls only when the window is too short for the whole list
                ViewThatFits(in: .vertical) {
                    rows
                    ScrollView { rows }
                        .scrollIndicators(.automatic)
                }

                HStack(spacing: 10) {
                    Spacer()
                    Button("Check again") { model.runCheckup() }
                        .buttonStyle(PillButtonStyle(small: true))
                        .disabled(model.checkupRunning)
                        .opacity(model.checkupRunning ? 0.5 : 1)
                    Button("Done") { model.closeCheckup() }
                        .buttonStyle(PillButtonStyle(primary: true, small: true))
                }
            }
            .padding(20)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panelSolid))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 25, y: 18)
            .padding(16)
        }
    }

    private var rows: some View {
        VStack(spacing: 8) {
            ForEach(model.checks) { check in
                CheckRow(check: check)
            }
        }
        .padding(.vertical, 14)
    }
}

private struct CheckRow: View {
    let check: SetupCheck

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            icon
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(check.title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(check.status == .pending ? Theme.muted : Theme.text)
                    .frame(minHeight: 22, alignment: .leading)
                if !check.text.isEmpty {
                    Text(check.text)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.raised))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }

    @ViewBuilder
    private var icon: some View {
        switch check.status {
        case .pending:
            ProgressView()
                .controlSize(.small)
                .tint(Theme.accent)
        case .good:
            badge("checkmark", Theme.good)
        case .warn:
            badge("exclamationmark", Theme.warn)
        case .bad:
            badge("xmark", Theme.danger)
        case .info:
            badge("info", Theme.muted)
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        ZStack {
            Circle().fill(color)
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .heavy))
                .foregroundStyle(Color(hex: 0x0B0D12))
        }
    }
}

// MARK: - Clock

/// The time in HH:MM AM/PM, like 09:05 PM. Redraws once a minute.
struct ClockView: View {
    private static let format: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "hh:mm a"
        return f
    }()

    var body: some View {
        TimelineView(.everyMinute) { context in
            Text(Self.format.string(from: context.date))
                .font(.system(size: 20, weight: .bold))
                .monospacedDigit()
                .kerning(0.4)
                .foregroundStyle(Color.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.black.opacity(0.45)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
                .fixedSize()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Stats

struct HUDView: View {
    @ObservedObject var live: LiveStats

    var body: some View {
        let values = live.hud
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 0) {
            row("Display delay", values.latency, color: color(for: values.latencyGrade))
            row("Frame rate", values.fps)
            row("Dropped frames", values.dropped)
            row("Audio delay", values.audio)
            row("Signal", values.signal)
            row("Scale", values.scale)
            row("Mode", values.mode)
        }
        .font(.system(size: 12))
        .monospacedDigit()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minWidth: 220)
        .fixedSize()
        .panel(radius: 12)
        .allowsHitTesting(false)
    }

    private func row(_ label: String, _ value: String, color: Color = Theme.text) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(Theme.muted)
                .frame(height: 21)
            Text(value)
                .foregroundStyle(color)
                .gridColumnAlignment(.trailing)
        }
    }

    private func color(for grade: HUDValues.Grade) -> Color {
        switch grade {
        case .none: return Theme.text
        case .good: return Theme.good
        case .ok: return Theme.warn
        case .bad: return Theme.danger
        }
    }
}

// MARK: - Recording indicator

struct RecordingIndicator: View {
    @ObservedObject var live: LiveStats

    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.6)) { context in
                let on = Int(context.date.timeIntervalSinceReferenceDate / 0.6) % 2 == 0
                Circle()
                    .fill(Theme.danger)
                    .frame(width: 9, height: 9)
                    .opacity(on ? 1 : 0.25)
                    .animation(.easeInOut(duration: 0.5), value: on)
            }
            .frame(width: 9, height: 9)
            Text(Self.format(live.recordingElapsed))
                .font(.system(size: 14, weight: .bold))
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Capsule().fill(Theme.panel))
        .overlay(Capsule().strokeBorder(Theme.danger.opacity(0.4), lineWidth: 1))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return "\(s / 60):\(String(format: "%02d", s % 60))"
    }
}

// MARK: - Tips

struct TipCard: View {
    @EnvironmentObject private var model: AppModel
    let tip: Tip

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tip.title)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.warn)
            Text(tip.text)
                .font(.system(size: 13))
                .foregroundStyle(Theme.text.opacity(0.88))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button("Got it") { model.closeTip(forever: false) }
                    .buttonStyle(PillButtonStyle(primary: true, small: true))
                Button("Don't show this again") { model.closeTip(forever: true) }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 6)
        }
        .padding(16)
        .frame(maxWidth: 330, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.panelSolid))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.warn.opacity(0.35), lineWidth: 1))
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Theme.panelSolid)
                .shadow(color: .black.opacity(0.45), radius: 25, y: 18)
        )
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Toasts

struct ToastStack: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.toasts) { toast in
                HStack(spacing: 14) {
                    Text(toast.message)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                    if let label = toast.actionLabel {
                        Button(label) { model.runToastAction(toast) }
                            .buttonStyle(.plain)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                    }
                }
                .padding(.leading, 16)
                .padding(.trailing, toast.actionLabel == nil ? 16 : 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.panelSolid))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.borderStrong, lineWidth: 1))
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.panelSolid)
                        .shadow(color: .black.opacity(0.45), radius: 25, y: 18)
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: model.toasts)
    }
}
