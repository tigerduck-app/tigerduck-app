import Foundation

/// Top-level visual presentation preset.
///
/// This is intentionally a presentation concern only — it decides which
/// rendering policy the UI applies, not which features exist, which data
/// flows, or which tint the user picks. It is a different dimension from
/// ``TimeSliderStyle`` (functional choice of slider) and from
/// `AppState.accentColorHex` (the user's theme accent color).
///
/// Designed to grow: adding a new preset only requires adding a case here
/// and extending ``VisualStylePolicy`` — no view is expected to branch on
/// the raw enum directly.
enum VisualPreset: String, CaseIterable, Identifiable, Sendable {
    /// TigerDuck's original visual language: saturated course colors on
    /// large surfaces, glass cards throughout, expressive time slider.
    case `default` = "default"

    /// Closer to iOS system language: neutral surfaces, course colors as
    /// small accents, restrained time slider, row/metadata-first cards.
    case iosInspired = "iosInspired"

    var id: String { rawValue }

    /// Localized name shown in Settings.
    var displayName: String {
        switch self {
        case .default: return "TigerDuck 風格"
        case .iosInspired: return "iOS 風格"
        }
    }
}
