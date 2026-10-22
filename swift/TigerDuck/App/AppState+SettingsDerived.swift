import SwiftUI
import Defaults
import os

extension AppState {

    var accentColor: Color {
        // Use bitPattern to avoid trapping on a corrupted-defaults negative
        // accentColorHex (Int → UInt conversion crashes on negative values).
        Color(hex: UInt(bitPattern: Int(accentColorHex)))
    }

    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

}
