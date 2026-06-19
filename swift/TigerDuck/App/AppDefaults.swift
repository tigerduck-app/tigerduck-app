import Defaults
import Foundation

extension BrowserPreference: Defaults.Serializable, Defaults.PreferRawRepresentable {}
extension MoodleOpenTarget: Defaults.Serializable, Defaults.PreferRawRepresentable {}
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
    /// Mac-only. Default `.browser` because the iPad Moodle app isn't
    /// installed by default on Mac; sending the user there before they
    /// opt in would fail with "no app handles this URL".
    static let macMoodleOpenTarget = Key<MoodleOpenTarget>(
        AppConstants.UserDefaultsKeys.macMoodleOpenTarget,
        default: .browser
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
    /// Default ON: the gesture is harmless when the parent library feature
    /// is off (which is itself default-off), and the first-trigger prompt
    /// gives users an explicit choice on their first accidental flip.
    static let flipToLibraryEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.flipToLibraryEnabled,
        default: true
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
    static let isAssignmentReminderEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.isAssignmentReminderEnabled,
        default: true
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
    static let classTableSelectedSemester = Key<String>(
        AppConstants.UserDefaultsKeys.classTableSelectedSemester,
        default: CourseSelectionService.currentSemesterCode()
    )
    static let homeAssignmentFilter = Key<String>(
        AppConstants.UserDefaultsKeys.homeAssignmentFilter,
        default: AssignmentFilter.incomplete.rawValue
    )

    // MARK: Cloud sync
    static let cloudSyncEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.cloudSyncEnabled,
        default: true
    )

    // MARK: Push server
    /// Default on as of the custom-push feature: every device registers on
    /// launch so operator-issued pushes can target it. Notification
    /// *permission* is still requested only via onboarding; the device row
    /// just exists either way. Users can opt out via `serverPushUserOptOut`.
    static let pushServerEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.pushServerEnabled,
        default: true
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
    /// User-facing opt-out for operator-issued "server" pushes. Default off
    /// (i.e. user is opted in). Backend reads the inverse as
    /// `server_push_enabled` and the dispatcher filters on
    /// `server_push_enabled = true`.
    static let serverPushUserOptOut = Key<Bool>(
        AppConstants.UserDefaultsKeys.serverPushUserOptOut,
        default: false
    )
    /// FIFO-capped set of custom-push popup ids the client has already
    /// rendered. Caps at 100 entries to dedupe replayed taps.
    static let shownServerPopupIds = Key<[String]>(
        AppConstants.UserDefaultsKeys.shownServerPopupIds,
        default: []
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

    // MARK: App-update prompt + What's New (iOS only — declared at the
    // cross-platform `Defaults.Keys` level because the keys themselves
    // are plain `String?` / `Date?` and the macOS build of `AppState`
    // does not reference any of these; the iOS-only update coordinator
    // is the sole reader/writer.

    static let skippedUpdateVersion = Key<String?>(
        AppConstants.UserDefaultsKeys.skippedUpdateVersion
    )
    static let lastUpdateCheckAt = Key<Date?>(
        AppConstants.UserDefaultsKeys.lastUpdateCheckAt
    )
    static let lastPromptedUpdateVersion = Key<String?>(
        AppConstants.UserDefaultsKeys.lastPromptedUpdateVersion
    )
    static let lastPromptedUpdateAt = Key<Date?>(
        AppConstants.UserDefaultsKeys.lastPromptedUpdateAt
    )
    static let lastShownWhatsNewVersion = Key<String?>(
        AppConstants.UserDefaultsKeys.lastShownWhatsNewVersion
    )
}
