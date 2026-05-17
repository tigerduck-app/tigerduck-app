import SwiftUI

/// Watch-side counterpart to the phone's `VisualStylePolicy`. Resolves a
/// `VisualPreset` (synced from the phone via `WatchSnapshot`) into the
/// rendering decisions the watch course cards need: whether the course
/// colour fills the card surface (TigerDuck) or just appears as a slim
/// accent stripe next to a neutral card (Apple).
///
/// Watch surfaces are intentionally simpler than the phone's — no glass
/// material, no per-platform branching — so this struct only carries
/// what the existing watch UI actually consumes. Adding a new preset
/// means extending this resolver, not branching on the raw enum from
/// every view.
struct WatchVisualStylePolicy {
    let preset: VisualPreset

    init(preset: VisualPreset) {
        self.preset = preset
    }

    /// Whether the card surface should be tinted with the course colour
    /// (`true`) or stay neutral with the colour shown only as a small
    /// accent stripe (`false`).
    var usesTintedCardSurface: Bool {
        switch preset {
        case .default: return true
        case .iosInspired: return false
        }
    }

    /// Background fill for a course card. In TigerDuck mode this is a
    /// muted wash of the course colour; in Apple mode it's a neutral
    /// gray surface that lets the accent stripe and text carry the
    /// course identity.
    func cardBackground(for courseColor: Color) -> Color {
        switch preset {
        case .default:
            return courseColor.opacity(0.28)
        case .iosInspired:
            return Color.white.opacity(0.08)
        }
    }
}
