import SwiftUI
import Defaults
import os

extension AppState {

    var accentColor: Color {
        Color(hex: UInt(bitPattern: Int(accentColorHex)))
    }

    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

}
