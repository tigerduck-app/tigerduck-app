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
    /// Print each course's room in the corner of its class-table cell.
    /// Off by default: the grid's job is which course, not where, and the
    /// cell is narrow enough that a second line is a deliberate trade.
    /// Device-local — display preferences are not part of the settings
    /// document the backend syncs.
    static let showClassroomInClassTable = Key<Bool>(
        AppConstants.UserDefaultsKeys.showClassroomInClassTable,
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
    // iOS-only: the default values come from LiveActivityPreferencesStore, which depends
    // on ActivityKit, and ActivityKit has no macOS equivalent. Every reader of these keys
    // is iOS-only too.
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
    /// This device has a reminder or Live Activity preference that the
    /// `notification` settings document has not acknowledged yet.
    ///
    /// Set when the preference changes and cleared only when a write lands, like
    /// `holidayOverridesAwaitingUpload`. While it is set, the next full sync re-sends
    /// (`AppState.retryUnacknowledgedNotificationSettings()`) and the edit wins over the
    /// document (`NotificationSettingsSync.reconcile` does not read over it). False by
    /// default: a fresh install has nothing outstanding.
    static let notificationSettingsPushPending = Key<Bool>(
        AppConstants.UserDefaultsKeys.notificationSettingsPushPending,
        default: false
    )
    /// Mirrors "an NTUST account exists" outside the Keychain, for UI gating.
    ///
    /// The Keychain returns nil when the item is absent and when it cannot be read right now;
    /// `SecureStore` cannot tell which, since Valet throws for both and `try?` flattens it.
    /// So nil is not evidence of being signed out; treating it so sends a signed-in user to
    /// the login prompt. UserDefaults stays readable when the Keychain is not, and the secret
    /// itself lives only in the Keychain. Raised by login and any successful credential
    /// read; lowered only by logout, the one time a nil read is authoritative.
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
    /// Up while the server may not hold what the six sync switches above
    /// say: raised before each sync-preferences PATCH, lowered once one
    /// lands with the switches unchanged. Registration carries none of
    /// them, so this is how a PATCH lost offline gets sent again — see
    /// `PushRegistrationService.updateSyncPreferences()`.
    static let syncPreferencesPushPending = Key<Bool>("syncPreferencesPushPending", default: false)
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
    /// Not a gate; read it only from `BulletinPushOptOutMigration`. A user can turn off
    /// a delivery channel (`bulletinPushEnabled`, `serverPushUserOptOut`) but never the
    /// registration, so every device past onboarding registers.
    ///
    /// A stored `false` is how the migration recognises a 2.0.x user who switched
    /// something off, and its own write of `true` records that it has read the key.
    /// Remove the key with the migration, per the lifecycle in `Services/Migrations/AGENTS.md`;
    /// the stored value left behind is a harmless orphan.
    static let pushServerEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.pushServerEnabled,
        default: true
    )
    /// Per-device bulletin push opt-out, separate from `serverPushUserOptOut` below,
    /// which is the operator-push channel alone. Positive polarity to match the
    /// `user_devices.bulletin_push_enabled` column it mirrors: do not invert it the way
    /// `serverPushUserOptOut` inverts `server_push_enabled`, or the bulletin page ends up
    /// double-negated.
    static let bulletinPushEnabled = Key<Bool>(
        AppConstants.UserDefaultsKeys.bulletinPushEnabled,
        default: true
    )
    static let pushServerURLOverride = Key<String?>(
        AppConstants.UserDefaultsKeys.pushServerURLOverride
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

    // MARK: App-update prompt + What's New (iOS only)
    // Declared for both platforms because the keys are plain `String?` / `Date?`;
    // the iOS-only update coordinator is their only reader and writer.

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
