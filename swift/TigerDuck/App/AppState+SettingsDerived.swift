// Pure derivations over Defaults-backed stored properties, which must stay on the
// class. These hold no state, so they can live in an extension. They are small and
// otherwise unrelated: accent color, visual preset.

import SwiftUI
import Defaults
import os

extension AppState {

    var accentColor: Color {
        // Use bitPattern to avoid trapping on a corrupted-defaults negative
        // accentColorHex (Int → UInt conversion crashes on negative values).
        Color(hex: UInt(bitPattern: Int(accentColorHex)))
    }

    /// Resolved presentation policy for the current preset. Views read
    /// from this instead of switching on ``visualPreset`` directly, so
    /// adding new presets stays contained to ``VisualStylePolicy``.
    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

}
