import AppKit
import SwiftUI

extension NSColor {
    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
}

extension Color {
    /// A colour that follows the window's effective appearance.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(hex: dark, alpha: darkAlpha) : NSColor(hex: light, alpha: lightAlpha)
        })
    }
}

/// The design's light and dark token sets (Main.dc.html `renderVals()`).
enum Theme {
    // Accent
    static let accent = Color(light: 0x0A6CFF, dark: 0x3D8BFF)
    static let accentSoft = Color(light: 0x0A6CFF, dark: 0x3D8BFF, lightAlpha: 0.12, darkAlpha: 0.2)
    static let accentGlow = Color(light: 0x0A6CFF, dark: 0x3D8BFF, lightAlpha: 0.3, darkAlpha: 0.35)

    // Text
    static let textPrimary = Color(light: 0x1D1D1F, dark: 0xF5F5F7)
    static let textSecondary = Color(light: 0x55555D, dark: 0xB4B4BD)
    static let textTertiary = Color(light: 0x6B6B74, dark: 0x9A9AA4)

    // Lines
    static let stroke = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.10)
    static let hairline = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.06)
    static let glassHighlight = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.85, darkAlpha: 0.10)

    // Surfaces
    static let surface = Color(light: 0xFFFFFF, dark: 0x242428, lightAlpha: 0.94, darkAlpha: 0.92)
    static let glass = Color(light: 0xFFFFFF, dark: 0x303036, lightAlpha: 0.5, darkAlpha: 0.52)
    static let cardGlass = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 0.55, darkAlpha: 0.06)
    static let inspector = Color(light: 0xFFFFFF, dark: 0x28282E, lightAlpha: 0.62, darkAlpha: 0.62)
    static let panel = Color(light: 0xFFFFFF, dark: 0x2C2C32, lightAlpha: 0.72, darkAlpha: 0.66)
    static let field = Color(light: 0xFFFFFF, dark: 0x1C1C20)
    /// The raised selected segment of a chip segmented control.
    static let segment = Color(light: 0xFFFFFF, dark: 0x5A5A63)
    static let group = Color(light: 0xFFFFFF, dark: 0xFFFFFF, lightAlpha: 1, darkAlpha: 0.06)
    static let tile = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.04, darkAlpha: 0.07)
    static let chip = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.05, darkAlpha: 0.08)
    static let track = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.08, darkAlpha: 0.12)
    static let grid = Color(light: 0x000000, dark: 0xFFFFFF, lightAlpha: 0.06, darkAlpha: 0.07)
    static let shadow = Color(light: 0x1E2850, dark: 0x000000, lightAlpha: 0.07, darkAlpha: 0.25)
    static let panelShadow = Color(light: 0x141E46, dark: 0x000000, lightAlpha: 0.18, darkAlpha: 0.45)

    // Window backdrop (the design's wallpaper gradient)
    static let wall = [Color(light: 0xCDDBF3, dark: 0x18233A),
                       Color(light: 0xE7DEF4, dark: 0x251D38),
                       Color(light: 0xD3ECE6, dark: 0x10302D)]

    // States
    static let green = Color(light: 0x18834A, dark: 0x3CCF7C)
    static let greenBadge = Color(light: 0x1F9D55, dark: 0x2FB36A)
    static let orange = Color(light: 0xA85A00, dark: 0xFFA53D)
    static let error = Color(light: 0xB42318, dark: 0xFF7A6E)
    static let errorSoft = Color(light: 0xB42318, dark: 0xFF7A6E, lightAlpha: 0.08, darkAlpha: 0.12)
    static let settingsSwitch = Color(light: 0x1F9D55, dark: 0x2FB36A)

    static func pill(_ status: ItemStatus) -> (foreground: Color, background: Color) {
        switch status {
        case .downloading: (accent, accentSoft)
        case .queued: (textSecondary, chip)
        case .paused: (Color(light: 0x9A5200, dark: 0xFFB35C),
                       Color(light: 0xC46A00, dark: 0xFFA53D, lightAlpha: 0.12, darkAlpha: 0.16))
        case .completed: (Color(light: 0x16733F, dark: 0x4FD88A),
                          Color(light: 0x18834A, dark: 0x3CCF7C, lightAlpha: 0.12, darkAlpha: 0.16))
        case .failed: (error, Color(light: 0xB42318, dark: 0xFF7A6E, lightAlpha: 0.10, darkAlpha: 0.16))
        }
    }

    /// A category's icon colour and its soft tile background.
    static func tint(_ category: Category) -> (foreground: Color, background: Color) {
        switch category {
        case .video: (Color(light: 0x8E3FD6, dark: 0xC58CFF),
                      Color(light: 0x8E3FD6, dark: 0xC58CFF, lightAlpha: 0.12, darkAlpha: 0.16))
        case .applications: (Color(light: 0x0A6CFF, dark: 0x5AA2FF),
                             Color(light: 0x0A6CFF, dark: 0x5AA2FF, lightAlpha: 0.12, darkAlpha: 0.16))
        case .archives: (Color(light: 0x9A6410, dark: 0xE0A446),
                         Color(light: 0xB87C1E, dark: 0xE0A446, lightAlpha: 0.14, darkAlpha: 0.16))
        case .documents: (Color(light: 0x0B7F79, dark: 0x3CC8BE),
                          Color(light: 0x0F8F8A, dark: 0x3CC8BE, lightAlpha: 0.12, darkAlpha: 0.16))
        case .music: (Color(light: 0xC72A6B, dark: 0xFF6FA3),
                      Color(light: 0xD63378, dark: 0xFF6FA3, lightAlpha: 0.12, darkAlpha: 0.16))
        case .other: (textSecondary, chip)
        }
    }
}
