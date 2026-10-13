import Foundation

/// Top-level visual presentation preset.
///
/// A presentation concern only: it picks the rendering policy the UI
/// applies, not which features exist, which data flows, or which tint the
/// user picks. The accent color, `AppState.accentColorHex`, is separate.
///
/// Adding a preset takes a case here and an extension of
/// ``VisualStylePolicy``; views should not branch on the raw enum.
public enum VisualPreset: String, CaseIterable, Identifiable, Sendable, Codable {
    /// TigerDuck's original visual language: saturated course colors on
    /// large surfaces, glass cards throughout, expressive time slider.
    case `default` = "default"

    /// Closer to iOS system language: neutral surfaces, course colors as
    /// small accents, restrained time slider, row/metadata-first cards.
    case iosInspired = "iosInspired"

    public var id: String { rawValue }

    /// Brand name shown in Settings. Not localized: these are platform/
    /// product proper nouns and read the same in every language.
    public var displayName: String {
        switch self {
        case .default: return "TigerDuck"
        case .iosInspired: return "Apple"
        }
    }
}
