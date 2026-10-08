import SwiftUI

/// Colors and shapes from the Windows version's stylesheet, so both apps feel the same.
enum Theme {
    static let background = Color(hex: 0x07080C)
    static let panel = Color(red: 16 / 255, green: 18 / 255, blue: 26 / 255).opacity(0.78)
    static let panelSolid = Color(hex: 0x11131B)
    static let raised = Color.white.opacity(0.06)
    static let raisedHover = Color.white.opacity(0.11)
    static let border = Color.white.opacity(0.09)
    static let borderStrong = Color.white.opacity(0.16)
    static let text = Color(hex: 0xEEF1F7)
    static let muted = Color(hex: 0x8E95A6)
    static let accent = Color(hex: 0x6AA8FF)
    static let accentStrong = Color(hex: 0x3D86F5)
    static let accentSoft = Color(hex: 0x6AA8FF).opacity(0.16)
    static let danger = Color(hex: 0xFF5C5C)
    static let good = Color(hex: 0x4ADE80)
    static let warn = Color(hex: 0xFBBF24)
}

extension Color {
    init(hex: UInt32) {
        self.init(
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255
        )
    }
}

/// A frosted panel with a hairline border, like `.bar` and `#hud` in the stylesheet.
struct PanelBackground: ViewModifier {
    var radius: CGFloat = 18
    var solid = false

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(solid ? AnyShapeStyle(Theme.panelSolid) : AnyShapeStyle(.ultraThinMaterial))
                    .overlay {
                        if !solid {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.panel)
                        }
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.45), radius: 25, y: 18)
    }
}

extension View {
    func panel(radius: CGFloat = 18, solid: Bool = false) -> some View {
        modifier(PanelBackground(radius: radius, solid: solid))
    }
}

/// Square icon buttons from the control bar. Pressed ones glow in the accent color.
struct IconButtonStyle: ButtonStyle {
    var active = false
    var tint = Theme.accent
    var idleColor = Theme.text

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(active ? tint : idleColor)
            .frame(width: 38, height: 38)
            .background {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(active ? tint.opacity(0.16) : (configuration.isPressed ? Theme.raisedHover : .clear))
            }
            .contentShape(Rectangle())
    }
}

/// Rounded pill buttons, like `.btn` in the stylesheet.
struct PillButtonStyle: ButtonStyle {
    var primary = false
    var small = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: small ? 13 : 14, weight: .semibold))
            .foregroundStyle(primary ? Color.white : Theme.text)
            .padding(.horizontal, small ? 12 : 16)
            .padding(.vertical, small ? 6 : 9)
            .background {
                Capsule().fill(primary ? AnyShapeStyle(LinearGradient(
                    colors: [Color(hex: 0x5B9CFF), Theme.accentStrong],
                    startPoint: .top,
                    endPoint: .bottom
                )) : AnyShapeStyle(Theme.raised))
            }
            .overlay {
                Capsule().strokeBorder(primary ? Color.white.opacity(0.18) : Theme.border, lineWidth: 1)
            }
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A segmented picker drawn like `.seg` in the stylesheet.
struct SegmentedChoice<Value: Hashable & Identifiable>: View {
    let options: [Value]
    let selection: Value
    var dimmed = false
    let label: (Value) -> String
    let choose: (Value) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let selected = option == selection
                Button {
                    choose(option)
                } label: {
                    Text(label(option))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : Theme.muted)
                        .padding(.horizontal, 11)
                        .frame(height: 30)
                        .background {
                            if selected {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(dimmed ? Theme.raisedHover : Theme.accentStrong)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.border, lineWidth: 1))
    }
}
