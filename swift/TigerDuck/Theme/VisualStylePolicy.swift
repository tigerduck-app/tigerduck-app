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
        case .default, .tat: return .primarySurface
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
        case .default, .tat: return .glass
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
        case .default, .tat: return .glass
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
        case .default, .tat: return .card
        case .iosInspired: return .groupedList
        }
    }

    // MARK: - Time slider prominence

    /// Opacity for the active course color block on the time slider.
    var timeSliderActiveSegmentOpacity: Double {
        switch preset {
        case .default, .tat: return 0.5
        case .iosInspired: return 0.22
        }
    }

    /// Opacity for inactive course color blocks on the time slider.
    var timeSliderInactiveSegmentOpacity: Double {
        switch preset {
        case .default, .tat: return 0.3
        case .iosInspired: return 0.10
        }
    }

    /// Whether the centre thumb should glow in the current course color,
    /// or stay a neutral white indicator.
    var timeSliderUsesCourseColoredThumb: Bool {
        switch preset {
        case .default, .tat: return true
        case .iosInspired: return false
        }
    }

    // MARK: - Text colors

    var primaryTextColor: Color {
        switch preset {
        case .default, .tat: return Color.textPrimary
        case .iosInspired: return .primary
        }
    }

    var secondaryTextColor: Color {
        switch preset {
        case .default, .tat: return Color.textSecondary
        case .iosInspired: return .secondary
        }
    }

    // MARK: - Class table

    enum ClassTableGridStyle: Sendable {
        /// A course's run of periods is one block, the period column shows each
        /// period's start and end, and an empty slot is a faint tile.
        case blocks
        /// Each period of a run is a tile of its own, the period column shows
        /// only the period, and rows alternate background bands while an empty
        /// slot stays bare.
        case periodTiles
    }

    var classTableGridStyle: ClassTableGridStyle {
        switch preset {
        case .default, .iosInspired: return .blocks
        case .tat: return .periodTiles
        }
    }

    /// A course's fill on the class table, conflict clusters included.
    func classTableCourseFill(_ courseColor: Color) -> Color {
        switch preset {
        case .default, .iosInspired: return courseColor.opacity(0.4)
        case .tat: return courseColor.pastel
        }
    }

    /// The outline of a required course on ``classTableCourseFill(_:)``.
    func classTableCourseOutline(_ courseColor: Color) -> Color {
        switch preset {
        case .default, .iosInspired: return courseColor
        case .tat: return courseColor.pastelOutline
        }
    }

    /// A course's name on ``classTableCourseFill(_:)``.
    var classTableCourseTextColor: Color {
        switch preset {
        case .default, .iosInspired: return Color.textPrimary
        case .tat: return Color.textOnPastel
        }
    }

    /// The room hint and the assignment marks on ``classTableCourseFill(_:)``.
    var classTableCourseSecondaryTextColor: Color {
        switch preset {
        case .default, .iosInspired: return Color.textSecondary
        case .tat: return Color.textOnPastelSecondary
        }
    }
}
