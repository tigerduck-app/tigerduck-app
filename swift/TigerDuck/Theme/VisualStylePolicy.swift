import SwiftUI

struct VisualStylePolicy: Sendable {
    let preset: VisualPreset

    init(preset: VisualPreset) {
        self.preset = preset
    }

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

    enum CardSurface: Sendable {
        case glass
        case grouped
    }

    var cardSurface: CardSurface {
        switch preset {
        case .default, .tat: return .glass
        case .iosInspired: return .grouped
        }
    }

    enum ChipStyle: Sendable {
        case glass
        case filledCapsule
    }

    var chipStyle: ChipStyle {
        switch preset {
        case .default, .tat: return .glass
        case .iosInspired: return .filledCapsule
        }
    }

    enum AssignmentRowStyle: Sendable {
        case card
        case groupedList
    }

    var assignmentRowStyle: AssignmentRowStyle {
        switch preset {
        case .default, .tat: return .card
        case .iosInspired: return .groupedList
        }
    }

    var timeSliderActiveSegmentOpacity: Double {
        switch preset {
        case .default, .tat: return 0.5
        case .iosInspired: return 0.22
        }
    }

    var timeSliderInactiveSegmentOpacity: Double {
        switch preset {
        case .default, .tat: return 0.3
        case .iosInspired: return 0.10
        }
    }

    var timeSliderUsesCourseColoredThumb: Bool {
        switch preset {
        case .default, .tat: return true
        case .iosInspired: return false
        }
    }

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

    enum ClassTableGridStyle: Sendable {
        case blocks
        case periodTiles
    }

    var classTableGridStyle: ClassTableGridStyle {
        switch preset {
        case .default, .iosInspired: return .blocks
        case .tat: return .periodTiles
        }
    }

    func classTableCourseFill(_ courseColor: Color) -> Color {
        switch preset {
        case .default, .iosInspired: return courseColor.opacity(0.3)
        case .tat: return courseColor.pastel
        }
    }

    func classTableCourseOutline(_ courseColor: Color) -> Color {
        switch preset {
        case .default, .iosInspired: return courseColor
        case .tat: return courseColor.pastelOutline
        }
    }

    var classTableCourseTextColor: Color {
        switch preset {
        case .default, .iosInspired: return Color.textPrimary
        case .tat: return Color.textOnPastel
        }
    }

    /// White names at the class table's small sizes look grey in thinner weights.
    var classTableCourseNameWeight: Font.Weight {
        switch preset {
        case .default, .iosInspired: return .semibold
        case .tat: return .medium
        }
    }

    var classTableCourseSecondaryTextColor: Color {
        switch preset {
        case .default, .iosInspired: return Color.textSecondary
        case .tat: return Color.textOnPastelSecondary
        }
    }
}
