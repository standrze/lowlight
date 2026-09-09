import SwiftTUI

/// Inherit the terminal's foreground/background with one consistent blue accent.
/// SwiftTUI supplies the detected appearance, including the browser host's theme.
struct LowlightPalette {
    let appearance: TerminalAppearance

    var ink: Color { appearance.foregroundColor }
    var brand: Color { accent }
    var accent: Color { Color(hexRGB: 0x6574CD) }
    var blue: Color { accent }
    var danger: Color { readable(light: 0xB33B38, dark: 0xFF938A) }
    var detailAccent: Color { muted }
    var muted: Color { readable(light: 0x596273, dark: 0xA3ADBC) }
    var border: Color { appearance.synthesizedTheme().separator }

    /// Keep supporting text and errors readable on unusual terminal themes.
    /// The brand accent deliberately stays the same color on every background.
    private func readable(light: UInt32, dark: UInt32) -> Color {
        let background = appearance.backgroundColor
        let lightColor = Color(hexRGB: light)
        let darkColor = Color(hexRGB: dark)
        let preferred = lightColor.contrastRatio(to: background) >= darkColor.contrastRatio(to: background)
            ? lightColor : darkColor
        if preferred.contrastRatio(to: background) >= 4.5 { return preferred }
        let target = Color.white.contrastRatio(to: background) >= Color.black.contrastRatio(to: background)
            ? Color.white : Color.black
        for step in 1...10 {
            let candidate = preferred.mixed(with: target, amount: Double(step) / 10)
            if candidate.contrastRatio(to: background) >= 4.5 { return candidate }
        }
        return target
    }
}
