import SwiftUI
import Defaults
import os

extension AppState {

    var accentColor: Color { Self.accentColor(hex: accentColorHex) }

    /// Orange, green and cyan read faintly on the light cards, so light mode draws an accent
    /// at the tone that reads there; dark mode keeps it as saved.
    static func accentColor(hex: Int) -> Color {
        // Use bitPattern to avoid trapping on a corrupted-defaults negative
        // accentColorHex (Int → UInt conversion crashes on negative values).
        let rgb = Int(UInt(bitPattern: hex) & 0xFFFFFF)
        return .adaptive(light: Color(hex: UInt(AccentContrast.readableOnLight(rgb))), dark: Color(hex: UInt(rgb)))
    }

    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

}
