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
    /// Pin every period — lunch (5) and the evening block (A–D) included —
    /// to the timetable even when no course uses them. Off by default: an
    /// empty evening is rows of nothing for the majority who never have a
    /// class there.
    static let alwaysShowAllPeriods = Key<Bool>(
        AppConstants.UserDefaultsKeys.alwaysShowAllPeriods,
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

    // MARK: Cloud sync
    static let cloudSyncEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.cloudSyncEnabled,
        default: true
    )
    /// "This device has a reminder/Live Activity preference the
    /// `notification` settings document has not acknowledged yet."
    ///
    /// Set when the preference changes, cleared only when a write actually
    /// lands. `AppState.retryUnacknowledgedNotificationSettings()` re-sends
    /// on the strength of it at the next full sync — the same
    /// mark-before / clear-on-success shape as
    /// `holidayOverridesAwaitingUpload`. Default `false`: a fresh install
    /// has nothing outstanding.
    static let notificationSettingsPushPending = Key<Bool>(
        AppConstants.UserDefaultsKeys.notificationSettingsPushPending,
        default: false
    )
    /// Mirrors "an NTUST account exists" outside the Keychain.
    ///
    /// The Keychain answers nil for two unrelated reasons — the item is
    /// absent, and the item cannot be read right now — and `SecureStore`
    /// cannot tell them apart, because Valet reports both as a thrown error
    /// that `try?` flattens. So a nil read is not evidence of being signed
    /// out, and treating it as such is what put a signed-in user on the
    /// login prompt until they pulled to refresh.
    ///
    /// UserDefaults is readable when the Keychain is not, which makes it the
    /// right place to answer "is there an account" for UI gating. The
    /// Keychain is still the only home of the secret itself.
    ///
    /// Raised by any successful credential read and by login; lowered only
    /// by logout, the one moment a nil read is authoritative because we just
    /// caused it.
    static let ntustCredentialsPresent = Key<Bool>(
        "ntustCredentialsPresent",
        default: false
    )
    static let syncCourses = Key<Bool>("syncCourses", default: true)
    static let syncCourseColors = Key<Bool>("syncCourseColors", default: true)
    static let syncCourseNames = Key<Bool>("syncCourseNames", default: true)
    static let syncAssignments = Key<Bool>("syncAssignments", default: true)
    /// Device-level: whether this device syncs its assignment-reminder
    /// preference to the server and wants the server to push assignment-due
    /// reminders to it, now that reminder scheduling has moved server-side.
    /// Distinct from `isAssignmentReminderEnabled` (the local on/off switch
    /// for the reminder feature itself, `LiveActivityPreferencesStore`) —
    /// this is "let this device receive that", not "want reminders at all".
    /// Default true: existing users keep receiving reminders after the
    /// upgrade, matching the backend column's `server_default`.
    static let syncAssignmentReminders = Key<Bool>("syncAssignmentReminders", default: true)
    /// Same shape as `syncAssignmentReminders`, for Live Activity.
    static let syncLiveActivity = Key<Bool>("syncLiveActivity", default: true)
    static let pendingConflictCategories = Key<Set<String>>("pendingConflictCategories", default: [])

    // MARK: Academic calendar
    /// Decoded `AcademicCalendar` from the last successful fetch. Cached so
    /// a cold launch with no network, and the widget extension, can still
    /// answer "is today a holiday".
    static let academicCalendarCache = Key<Data>("academicCalendarCache", default: Data())
    /// ETag of that payload, so the launch-time refresh costs a 304 rather
    /// than a full body when nothing changed.
    static let academicCalendarETag = Key<String>("academicCalendarETag", default: "")
    /// Holidays the user asked to keep receiving class reminders on.
    ///
    /// Written whether or not cloud sync is on — the holiday guard is not a
    /// sync feature — and additionally uploaded when sync is enabled so a
    /// user's devices agree. Ids rather than dates because an operator can
    /// edit a holiday's range after the user opted in, and the opt-in should
    /// follow the holiday.
    static let holidayNotifyOverrides = Key<[Int]>("holidayNotifyOverrides", default: [])
    /// Holiday toggles the backend has not acknowledged yet — an upload that
    /// failed, or one still in flight when the app was killed. Persisted so a
    /// restart between the failure and the next sync does not quietly hand the
    /// user's choice back to the server. See
    /// ``AcademicCalendarStore/applySyncedOverrides(_:fetchedAt:)``.
    static let holidayOverridesAwaitingUpload = Key<[Int]>(
        "holidayOverridesAwaitingUpload", default: []
    )

    // MARK: Push server
    /// Default on as of the custom-push feature: every device registers
    /// once onboarding is complete, so operator-issued pushes can target it.
    /// Notification *permission* is still requested only via onboarding; the
    /// device row just exists either way. Users can opt out via
    /// `serverPushUserOptOut`. `AppState` gates the launch-time enable on
    /// `hasCompletedOnboarding` so no device identity is sent pre-consent.
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
