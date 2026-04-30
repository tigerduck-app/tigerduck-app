import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Top-level visual presentation preset.
///
/// This is intentionally a presentation concern only — it decides which
/// rendering policy the UI applies, not which features exist, which data
/// flows, or which tint the user picks. It is a different dimension from
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

    /// Brand name shown in Settings. Not localized: these are platform/
    /// product proper nouns and read the same in every language.
    var displayName: String {
        switch self {
        case .default: return "TigerDuck"
        case .iosInspired: return Self.systemPlatformName
        }
    }

    private static var systemPlatformName: String {
        #if os(macOS)
        return "macOS"
        #elseif targetEnvironment(macCatalyst)
        return "macOS"
        #elseif canImport(UIKit)
        switch UIDevice.current.userInterfaceIdiom {
        case .pad: return "iPadOS"
        case .mac: return "macOS"
        case .tv: return "tvOS"
        case .vision: return "visionOS"
        default: return "iOS"
        }
        #else
        return "iOS"
        #endif
    }
}
