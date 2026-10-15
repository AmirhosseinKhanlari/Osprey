import SwiftUI

/// The design's capsule buttons: an accent primary, a tile-coloured secondary and an accent text button.
struct CapsuleButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }

    var kind: Kind
    var height: CGFloat = 30
    var fontSize: CGFloat = 12.5
    var fillWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: fontSize, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, kind == .primary ? 16 : (kind == .secondary ? 14 : 12))
            .frame(maxWidth: fillWidth ? .infinity : nil)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background { background }
            .contentShape(Capsule())
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.45)
    }

    private var foreground: Color {
        switch kind {
        case .primary: .white
        case .secondary: Theme.textPrimary
        case .text: Theme.accent
        }
    }

    @ViewBuilder private var background: some View {
        switch kind {
        case .primary:
            Capsule().fill(Theme.accent)
                .overlay(Capsule().strokeBorder(.white.opacity(0.18)))
                .shadow(color: Theme.accentGlow, radius: 7, y: 4)
        case .secondary:
            Capsule().fill(Theme.chip)
                .overlay(Capsule().strokeBorder(Theme.stroke))
        case .text:
            Color.clear
        }
    }
}

extension ButtonStyle where Self == CapsuleButtonStyle {
    static func capsule(_ kind: CapsuleButtonStyle.Kind, height: CGFloat = 30, fontSize: CGFloat = 12.5,
                        fillWidth: Bool = false) -> CapsuleButtonStyle {
        CapsuleButtonStyle(kind: kind, height: height, fontSize: fontSize, fillWidth: fillWidth)
    }
}
