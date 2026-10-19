import AppKit
import FaceLockCore
import SwiftUI

struct ColorPair: Sendable {
    let light: UInt32
    let dark: UInt32
}

/// The FaceLock palette. Mulberry is the accent; fern, amber and brick are reserved for state.
enum Palette {
    static let mulberry = ColorPair(light: 0x8A3A78, dark: 0xD98AC4)
    static let onMulberry = ColorPair(light: 0xFFFFFF, dark: 0x2A0F24)
    static let smoke = ColorPair(light: 0x6E6670, dark: 0xA39AA4)
    static let fern = ColorPair(light: 0x2F7D4A, dark: 0x5DBE7E)
    static let amber = ColorPair(light: 0x9A6200, dark: 0xE8A93C)
    static let brick = ColorPair(light: 0xB3342E, dark: 0xEF6B63)
    static let ink = ColorPair(light: 0x1B1720, dark: 0x0F0C12)
}

extension NSColor {
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    static func adaptive(_ pair: ColorPair) -> NSColor {
        NSColor(name: nil) { appearance in
            NSColor(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light)
        }
    }
}

extension Color {
    init(_ pair: ColorPair) {
        self.init(nsColor: .adaptive(pair))
    }
}

enum Theme {
    static let accent = Color(Palette.mulberry)
    static let onAccent = Color(Palette.onMulberry)
    static let neutral = Color(Palette.smoke)
    static let good = Color(Palette.fern)
    static let warning = Color(Palette.amber)
    static let critical = Color(Palette.brick)
    /// The camera well behind a preview, in both appearances.
    static let well = Color(Palette.ink)
    static let track = Color.primary.opacity(0.1)
    static let surface = Color.primary.opacity(0.05)
    static let hover = Color.primary.opacity(0.08)

    static func tone(_ t: StatusTone) -> Color {
        switch t {
        case .good: return good
        case .warning: return warning
        case .critical: return critical
        case .neutral: return neutral
        }
    }
}

/// One spacing step per level: 4 inside a control, 8 inside a group, 16 between groups, 24 around sections.
enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

/// Concentric radii: a card holding an 8 pt inset control is 6 + 8.
enum Radius {
    static let inner: CGFloat = 6
    static let control: CGFloat = 8
    static let card: CGFloat = 14
    static let well: CGFloat = 18
}

/// DIN Alternate (on every Mac since 10.11) carries the display role: step headlines, the
/// countdown numeral and the menu's state headline. SF Pro does everything else.
enum Typeface {
    static let displayName = "DINAlternate-Bold"
    static let hasDisplay = NSFont(name: displayName, size: 12) != nil

    static func display(_ size: CGFloat) -> Font {
        hasDisplay ? .custom(displayName, fixedSize: size) : .system(size: size, weight: .bold)
    }

    static let countdown = display(56)
    static let headline = display(28)
    static let title = display(20)
    static let state = display(17)
    static let body = Font.system(size: 13)
    static let bodyEmphasis = Font.system(size: 13, weight: .semibold)
    static let caption = Font.system(size: 11)
    static let data = Font.system(size: 12, design: .monospaced)
}

extension View {
    func readableWidth() -> some View { frame(maxWidth: 460, alignment: .leading) }
}
