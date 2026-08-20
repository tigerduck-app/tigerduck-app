import Defaults
import Foundation

extension BrowserPreference: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension VisualPreset: Defaults.Serializable, Defaults.PreferRawRepresentable {}

nonisolated extension Defaults.Keys {
    static let hasCompletedOnboarding = Key<Bool>(
        AppConstants.UserDefaultsKeys.hasCompletedOnboarding,
        default: false
    )
    static let appHasBeenInstalled = Key<Bool>(
        AppConstants.UserDefaultsKeys.appHasBeenInstalled,
        default: false
    )
    static let accentColorHex = Key<Int>(
        AppConstants.UserDefaultsKeys.accentColorHex,
        default: 0x007AFF
    )
    static let rememberAnnouncementFilter = Key<Bool>(
        AppConstants.UserDefaultsKeys.rememberAnnouncementFilter,
        default: false
    )
    static let savedAnnouncementDepartmentsData = Key<Data?>(
        AppConstants.UserDefaultsKeys.savedAnnouncementDepartments
    )
    static let browserPreference = Key<BrowserPreference>(
        AppConstants.UserDefaultsKeys.browserPreference,
        default: .system
    )
    static let showAbsoluteAssignmentTime = Key<Bool>(
        AppConstants.UserDefaultsKeys.showAbsoluteAssignmentTime,
        default: false
    )
    static let configuredTabsData = Key<Data?>(
        AppConstants.UserDefaultsKeys.configuredTabs
    )
    static let macConfiguredTabsData = Key<Data?>(
        AppConstants.UserDefaultsKeys.macConfiguredTabs
    )
    static let invertSliderDirection = Key<Bool>(
        AppConstants.UserDefaultsKeys.invertSliderDirection,
        default: false
    )
    static let libraryFeatureEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.libraryFeatureEnabled,
        default: false
    )
    static let homeSectionLayoutData = Key<Data?>(
        AppConstants.UserDefaultsKeys.homeSectionLayout
    )
    static let visualPreset = Key<VisualPreset>(
        AppConstants.UserDefaultsKeys.visualPreset,
        default: .default
    )
    static let assignmentReminderOffsetsData = Key<Data?>(
        AppConstants.UserDefaultsKeys.assignmentReminderOffsets
    )
    static let isLiveActivityEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.isLiveActivityEnabled,
        default: true
    )
    #if os(iOS)
    // Defaults whose default value comes from the iOS-only
    // LiveActivityPreferencesStore. Wrapped because the store itself
    // depends on ActivityKit, which has no macOS equivalent. The reader
    // side (`LiveActivityPreferencesStore.assignmentLiveActivityLeadTime`
    // etc.) is also iOS-only, so consumers of these keys live entirely
    // in the iOS code path.
    static let assignmentLiveActivityLeadTime = Key<Double>(
        AppConstants.UserDefaultsKeys.assignmentLiveActivityLeadTime,
        default: LiveActivityPreferencesStore.defaultAssignmentLeadTime
    )
    static let classPreparingLeadTime = Key<Double>(
        AppConstants.UserDefaultsKeys.classPreparingLeadTime,
        default: LiveActivityPreferencesStore.defaultClassPreparingLeadTime
    )
    #endif
    static let showAssignmentScenario = Key<Bool>(
        AppConstants.UserDefaultsKeys.showAssignmentScenario,
        default: true
    )
    static let showClassPreparingScenario = Key<Bool>(
        AppConstants.UserDefaultsKeys.showClassPreparingScenario,
        default: true
    )
    static let showInClassScenario = Key<Bool>(
        AppConstants.UserDefaultsKeys.showInClassScenario,
        default: true
    )
    static let ssoLoginTimestamp = Key<Double?>(AppConstants.UserDefaultsKeys.ssoLoginTimestamp)
    static let moodleTokenMigrationDone = Key<Bool>(
        "moodleTokenMigrationDone",
        default: false
    )
    /// Optional on purpose: `nil` means "never picked a semester", which
    /// `SemesterCatalog.selectedSemester(storedPick:)` resolves to the newest
    /// published term. A non-optional key with a computed default cannot tell
    /// the two apart, so an untouched picker would freeze on whichever term
    /// was newest at first launch.
    static let classTableSelectedSemester = Key<String?>(
        AppConstants.UserDefaultsKeys.classTableSelectedSemester
    )
    static let homeAssignmentFilter = Key<String>(
        AppConstants.UserDefaultsKeys.homeAssignmentFilter,
        default: AssignmentFilter.incomplete.rawValue
    )

    // MARK: Push server
    /// Default off: device tokens / metadata are POSTed to the push server
    /// only after the user explicitly opts in. The previous default sent
    /// device data on first launch with no consent surface.
    static let pushServerEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.pushServerEnabled,
        default: false
    )
    static let pushServerURLOverride = Key<String?>(
        AppConstants.UserDefaultsKeys.pushServerURLOverride
    )
    static let pushLastRegistrationAt = Key<Date?>(
        AppConstants.UserDefaultsKeys.pushLastRegistrationAt
    )
    static let pushLastSyncAt = Key<Date?>(
        AppConstants.UserDefaultsKeys.pushLastSyncAt
    )

    // MARK: Bulletins
    static let bulletinReadIds = Key<Set<Int>>(
        AppConstants.UserDefaultsKeys.bulletinReadIds,
        default: []
    )

    // MARK: Language & Abbreviations
    static let appLanguage = Key<String>(
        AppConstants.UserDefaultsKeys.appLanguage,
        default: "system"
    )
    static let useEnglishCourseAbbreviation = Key<Bool>(
        AppConstants.UserDefaultsKeys.useEnglishCourseAbbreviation,
        default: true
    )
    static let useEnglishClassroomAbbreviation = Key<Bool>(
        AppConstants.UserDefaultsKeys.useEnglishClassroomAbbreviation,
        default: true
    )
    static let classroomMandarinDisplay = Key<String>(
        AppConstants.UserDefaultsKeys.classroomMandarinDisplay,
        default: "original"
    )
}
