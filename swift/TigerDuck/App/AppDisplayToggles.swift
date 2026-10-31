import Defaults
import Foundation

/// The display preferences that only store their value, each written back to its Defaults key.
struct AppDisplayToggles {
    var accentColorHex: Int = Defaults[.accentColorHex] {
        didSet { Defaults[.accentColorHex] = accentColorHex }
    }

    /// Mac only: where the "open in Moodle" actions route to. The iPad Moodle app installed from
    /// the Mac App Store registers `moodlemobile://` too, so its users can choose the deep link.
    var macMoodleOpenTarget: MoodleOpenTarget = Defaults[.macMoodleOpenTarget] {
        didSet { Defaults[.macMoodleOpenTarget] = macMoodleOpenTarget }
    }

    var invertSliderDirection: Bool = Defaults[.invertSliderDirection] {
        didSet { Defaults[.invertSliderDirection] = invertSliderDirection }
    }

    var showAbsoluteAssignmentTime: Bool = Defaults[.showAbsoluteAssignmentTime] {
        didSet { Defaults[.showAbsoluteAssignmentTime] = showAbsoluteAssignmentTime }
    }

    var alwaysShowAllPeriods: Bool = Defaults[.alwaysShowAllPeriods] {
        didSet { Defaults[.alwaysShowAllPeriods] = alwaysShowAllPeriods }
    }

    var showClassroomInClassTable: Bool = Defaults[.showClassroomInClassTable] {
        didSet { Defaults[.showClassroomInClassTable] = showClassroomInClassTable }
    }

    var flipToLibraryEnabled: Bool = Defaults[.flipToLibraryEnabled] {
        didSet { Defaults[.flipToLibraryEnabled] = flipToLibraryEnabled }
    }

    var visualPreset: VisualPreset = Defaults[.visualPreset] {
        didSet { Defaults[.visualPreset] = visualPreset }
    }
}
