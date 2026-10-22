import SwiftUI

struct WatchVisualStylePolicy {
    let preset: VisualPreset

    init(preset: VisualPreset) {
        self.preset = preset
    }

    var usesTintedCardSurface: Bool {
        switch preset {
        case .default, .tat: return true
        case .iosInspired: return false
        }
    }

    func cardBackground(for courseColor: Color) -> Color {
        switch preset {
        case .default, .tat:
            return courseColor.opacity(0.28)
        case .iosInspired:
            return Color.white.opacity(0.08)
        }
    }
}
