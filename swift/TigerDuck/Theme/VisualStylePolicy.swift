import SwiftUI

/// Central resolver that maps a ``VisualPreset`` into concrete
/// presentation decisions (card surfaces, accent usage, slider color
/// prominence, chip treatment, row layout, etc).
///
/// Views should read from this policy rather than branching on the raw
/// ``VisualPreset`` — that keeps the enum open for extension and stops
/// `if preset == .iosInspired` scattering through view code.
struct VisualStylePolicy: Sendable {
    let preset: VisualPreset

    init(preset: VisualPreset) {
        self.preset = preset
    }

    // MARK: - Course color usage

    /// Whether a course-colored surface should dominate the card, or
    /// whether the course color should only appear as a small accent.
    enum CourseColorUsage: Sendable {
        case primarySurface
        case smallAccent
    }

    var courseColorUsage: CourseColorUsage {
        switch preset {
        case .default: return .primarySurface
        case .iosInspired: return .smallAccent
        }
    }

    // MARK: - Card surface

    /// How large content cards render their background.
    enum CardSurface: Sendable {
        /// TigerDuck glass — `.ultraThinMaterial` with soft drop shadow.
        case glass
        /// iOS grouped list surface — `secondarySystemGroupedBackground`
        /// with a hairline border and no shadow.
        case grouped
    }

    var cardSurface: CardSurface {
        switch preset {
        case .default: return .glass
        case .iosInspired: return .grouped
        }
    }

    // MARK: - Chip style (used by announcements filter row)

    enum ChipStyle: Sendable {
        /// Glass material capsule with accent fill when selected.
        case glass
        /// iOS-style filled capsule (tinted when selected, `.quaternary`
        /// when not) with no material.
        case filledCapsule
    }

    var chipStyle: ChipStyle {
        switch preset {
        case .default: return .glass
        case .iosInspired: return .filledCapsule
        }
    }

    // MARK: - Assignment row style

    enum AssignmentRowStyle: Sendable {
        /// Each assignment renders inside its own glass card.
        case card
        /// Assignments render as rows inside a single grouped surface,
        /// separated by hairline dividers.
        case groupedList
    }

    var assignmentRowStyle: AssignmentRowStyle {
        switch preset {
        case .default: return .card
        case .iosInspired: return .groupedList
        }
    }

    // MARK: - Time slider prominence

    /// Opacity for the active course color block on the time slider.
    var timeSliderActiveSegmentOpacity: Double {
        switch preset {
        case .default: return 0.5
        case .iosInspired: return 0.22
        }
    }

    /// Opacity for inactive course color blocks on the time slider.
    var timeSliderInactiveSegmentOpacity: Double {
        switch preset {
        case .default: return 0.3
        case .iosInspired: return 0.10
        }
    }

    /// Whether the centre thumb should glow in the current course color,
    /// or stay a neutral white indicator.
    var timeSliderUsesCourseColoredThumb: Bool {
        switch preset {
        case .default: return true
        case .iosInspired: return false
        }
    }

    /// Opacity of the course-color tint applied to segmented-bar buttons.
    /// In iOS preset we almost remove the tint so the bar reads as a row
    /// of neutral capsules with colored *labels*, not colored *surfaces*.
    func segmentedBarTintOpacity(isSelected: Bool) -> Double {
        switch preset {
        case .default:
            return isSelected ? 0.4 : 0.15
        case .iosInspired:
            return isSelected ? 0.18 : 0.06
        }
    }

    // MARK: - Search-bar surface (announcements)

    enum SearchBarSurface: Sendable {
        case glass
        case grouped
    }

    var searchBarSurface: SearchBarSurface {
        switch preset {
        case .default: return .glass
        case .iosInspired: return .grouped
        }
    }
}
