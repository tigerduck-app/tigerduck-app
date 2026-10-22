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
    static let browserPreference = Key<BrowserPreference>(
        AppConstants.UserDefaultsKeys.browserPreference,
        default: .system
    )
    static let macMoodleOpenTarget = Key<MoodleOpenTarget>(
        AppConstants.UserDefaultsKeys.macMoodleOpenTarget,
        default: .browser
    )
    static let showAbsoluteAssignmentTime = Key<Bool>(
        AppConstants.UserDefaultsKeys.showAbsoluteAssignmentTime,
        default: false
    )
    static let alwaysShowAllPeriods = Key<Bool>(
        AppConstants.UserDefaultsKeys.alwaysShowAllPeriods,
        default: false
    )
    static let showClassroomInClassTable = Key<Bool>(
        AppConstants.UserDefaultsKeys.showClassroomInClassTable,
        default: true
    )
    static let pinTodayCoursesOnClassTable = Key<Bool>(
        AppConstants.UserDefaultsKeys.pinTodayCoursesOnClassTable,
        default: false
    )
    static let outlineRequiredCourses = Key<Bool>(
        AppConstants.UserDefaultsKeys.outlineRequiredCourses,
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
    static let flipToLibraryEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.flipToLibraryEnabled,
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
    static let isAssignmentReminderEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.isAssignmentReminderEnabled,
        default: true
    )
    static let isClassReminderEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.isClassReminderEnabled,
        default: true
    )
    static let hasPickedClassReminderLead = Key<Bool>(
        AppConstants.UserDefaultsKeys.hasPickedClassReminderLead,
        default: false
    )
    static let isLiveActivityEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.isLiveActivityEnabled,
        default: true
    )
    #if os(iOS)
    static let assignmentLiveActivityLeadTime = Key<Double>(
        AppConstants.UserDefaultsKeys.assignmentLiveActivityLeadTime,
        default: LiveActivityPreferencesStore.defaultAssignmentLeadTime
    )
    static let classPreparingLeadTime = Key<Double>(
        AppConstants.UserDefaultsKeys.classPreparingLeadTime,
        default: LiveActivityPreferencesStore.defaultClassPreparingLeadTime
    )
    static let classReminderLeadMinutes = Key<Int>(
        AppConstants.UserDefaultsKeys.classReminderLeadMinutes,
        default: LiveActivityPreferencesStore.defaultClassReminderLeadMinutes
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
    static let schoolDataSyncedAt = Key<Date?>("schoolDataSyncedAt")
    static let bulletinsSyncedAt = Key<Date?>("bulletinsSyncedAt")
    static let lastSeenCoursesResetAt = Key<Date?>("lastSeenCoursesResetAt")
    static let classTableSelectedSemester = Key<String?>(
        AppConstants.UserDefaultsKeys.classTableSelectedSemester
    )
    static let emptyClassroomBuilding = Key<String?>("emptyClassroomBuilding")
    static let homeAssignmentFilter = Key<String>(
        AppConstants.UserDefaultsKeys.homeAssignmentFilter,
        default: AssignmentFilter.incomplete.rawValue
    )

    static let cloudSyncEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.cloudSyncEnabled,
        default: true
    )
    static let notificationSettingsPushPending = Key<Bool>(
        AppConstants.UserDefaultsKeys.notificationSettingsPushPending,
        default: false
    )
    static let ntustCredentialsPresent = Key<Bool>(
        "ntustCredentialsPresent",
        default: false
    )
    static let ntustStoredPasswordRefusals = Key<Int>("ntustStoredPasswordRefusals", default: 0)
    static let ntustStoredPasswordRefusedAt = Key<Date?>("ntustStoredPasswordRefusedAt")
    static let libraryStoredPasswordRejected = Key<Bool>("libraryStoredPasswordRejected", default: false)
    static let syncCourses = Key<Bool>("syncCourses", default: true)
    static let syncCourseColors = Key<Bool>("syncCourseColors", default: true)
    static let syncCourseNames = Key<Bool>("syncCourseNames", default: true)
    static let syncAssignments = Key<Bool>("syncAssignments", default: true)
    static let syncAssignmentReminders = Key<Bool>("syncAssignmentReminders", default: true)
    static let syncLiveActivity = Key<Bool>("syncLiveActivity", default: true)
    static let syncPreferencesPushPending = Key<Bool>("syncPreferencesPushPending", default: false)
    static let pendingConflictCategories = Key<Set<String>>("pendingConflictCategories", default: [])
    static let assignmentMarksSyncedOnce = Key<Bool>("assignmentMarksSyncedOnce", default: false)
    static let categoriesSyncedOnce = Key<Set<String>>("categoriesSyncedOnce", default: [])
    static let courseRowIdsSeen = Key<[String: Int]>("courseRowIdsSeen", default: [:])

    static let academicCalendarCache = Key<Data>("academicCalendarCache", default: Data())
    static let academicCalendarETag = Key<String>("academicCalendarETag", default: "")
    static let holidayNotifyOverrides = Key<[Int]>("holidayNotifyOverrides", default: [])
    static let holidayOverridesAwaitingUpload = Key<[Int]>(
        "holidayOverridesAwaitingUpload", default: []
    )

    static let pushServerEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.pushServerEnabled,
        default: true
    )
    static let bulletinPushEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.bulletinPushEnabled,
        default: true
    )
    static let pushServerURLOverride = Key<String?>(
        AppConstants.UserDefaultsKeys.pushServerURLOverride
    )
    static let serverPushUserOptOut = Key<Bool>(
        AppConstants.UserDefaultsKeys.serverPushUserOptOut,
        default: false
    )
    static let shownServerPopupIds = Key<[String]>(
        AppConstants.UserDefaultsKeys.shownServerPopupIds,
        default: []
    )

    static let bulletinReadIds = Key<Set<Int>>(
        AppConstants.UserDefaultsKeys.bulletinReadIds,
        default: []
    )

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

    static let skippedUpdateVersion = Key<String?>(
        AppConstants.UserDefaultsKeys.skippedUpdateVersion
    )
    static let lastUpdateCheckAt = Key<Date?>(
        AppConstants.UserDefaultsKeys.lastUpdateCheckAt
    )
    static let lastReportedUnparseableStoreVersion = Key<String?>(
        AppConstants.UserDefaultsKeys.lastReportedUnparseableStoreVersion
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
