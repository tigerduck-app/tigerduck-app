import Foundation

extension URL {
    /// Force-construct a URL from a static string literal that the
    /// caller treats as compile-time-known-good. The `URL(string:)!`
    /// pattern crashes on first access for an opaque "fatal error: nil"
    /// — almost always a typo, leading whitespace, or accidental
    /// Unicode in a future edit. `knownGood` traps with the offending
    /// string in the diagnostic so the regression is obvious in crash
    /// reports. Also throws at the type-load site so static service
    /// URLs cannot ship with a malformed literal.
    nonisolated static func knownGood(_ string: StaticString) -> URL {
        let raw = "\(string)"
        guard let url = URL(string: raw) else {
            preconditionFailure("URL.knownGood received a malformed literal: \(raw)")
        }
        return url
    }
}

nonisolated enum AppConstants {
    static let appName = "TigerDuck"

    /// All "what day/time is it?" logic must read this, not the device
    /// timezone — NTUST's class table, ICS feed, and Moodle deadlines are
    /// all authored in Taipei wall time, so a student abroad must still
    /// see "Monday 08:10" when the schedule says Monday 08:10.
    static let taipeiTimeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    /// Gregorian + Asia/Taipei. Use everywhere `Calendar.current` would
    /// otherwise drift the displayed weekday/day on a device set to a
    /// non-Taiwan timezone or a non-gregorian calendar (ROC, Buddhist).
    static let taipeiCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = taipeiTimeZone
        return cal
    }()

    /// The academic term the app currently considers "now".
    ///
    /// ponytail: hard-coded. Nothing in the app knows when classes actually
    /// start or end — `CourseSelectionService.currentSemesterCode()` is a
    /// month heuristic that only guesses the *term code*, and the semester
    /// catalogue reports which term 選課 has open, which runs weeks ahead of
    /// the term in session. Swap `code`/`start`/`end` for the academic
    /// calendar feed (`CalendarService` already fetches the ICS that carries
    /// 開學/結業) when that lands; every consumer reads `code` or
    /// `isInSession` and needs no change.
    enum CurrentTerm {
        /// 115 學年度第 1 學期.
        static let code = "1151"

        /// First day of classes, Taipei wall time.
        static let start = taipeiDate(year: 2026, month: 9, day: 7)
        /// Exclusive upper bound — the day *after* the last day of classes,
        /// so 2026-12-25 counts as in session right up to midnight.
        static let end = taipeiDate(year: 2026, month: 12, day: 26)

        /// True while classes are in session.
        ///
        /// Gates the "today"-scoped surfaces — Home's time slider and the
        /// class table's today carousel — which outside the term would
        /// either sit empty or scrub a day that has no classes.
        static var isInSession: Bool {
            let now = AppClock.now()
            return now >= start && now < end
        }

        /// Fails closed: an unbuildable date lands in the distant future, so
        /// `isInSession` reads false rather than true-forever.
        private static func taipeiDate(year: Int, month: Int, day: Int) -> Date {
            var components = DateComponents()
            components.year = year
            components.month = month
            components.day = day
            return AppConstants.taipeiCalendar.date(from: components) ?? .distantFuture
        }
    }

    static let dataDidUpdate = Notification.Name("TigerDuck.dataDidUpdate")
    static let liveActivityPreferencesDidChange = Notification.Name("TigerDuck.liveActivityPreferencesDidChange")
    static let languageDidChange = Notification.Name("TigerDuck.languageDidChange")
    /// Posted when a course's per-date skip state mutates. Drives the
    /// Live Activity refresh so a user marking the current class as
    /// skipped sees the lock-screen activity update without waiting
    /// for the next sync tick.
    static let courseSkipStateDidChange = Notification.Name("TigerDuck.courseSkipStateDidChange")
    /// Posted when the per-course color assignment map mutates (user
    /// picked a custom color, reassigned all, or a course got displaced
    /// during a setColor uniqueness rebalance). Drives the widget
    /// snapshot rewrite so home-screen widgets follow in-app colors
    /// without waiting for the next data sync.
    static let courseColorMapDidChange = Notification.Name("TigerDuck.courseColorMapDidChange")
    static let moodleBaseURL = URL.knownGood("https://moodle2.ntust.edu.tw")

    nonisolated enum KeychainKeys {
        static let studentId = "ntust_student_id"
        static let password = "ntust_password"
        static let libraryUsername = "library_username"
        static let libraryPassword = "library_password"
        static let libraryToken = "library_token"
        static let libraryTokenExpiry = "library_token_expiry"
        static let moodleToken = "moodle_token"
        static let moodlePrivateToken = "moodle_private_token"
        static let pushUserId = "push_user_id"
        static let pushDeviceId = "push_device_id"
    }

    /// Production push/bulletin backend. Release builds always resolve here.
    /// Debug builds resolve through ``PushCoordinator/resolveServerURL()``,
    /// which reads per-developer `Secrets.plist["DebugServerURL"]` (gitignored)
    /// or falls back to ``fallbackDebugPushServerURL`` for Simulator setups.
    static let productionPushServerURL = URL.knownGood("https://api.tigerduck.app/v2")

    /// Default Debug-build endpoint when `Secrets.plist` has no `DebugServerURL`.
    /// Works on Simulator (localhost = host Mac); on a physical device this
    /// resolves to the device itself and will fail to connect — physical-device
    /// contributors must set `DebugServerURL` to their Mac's LAN IP.
    static let fallbackDebugPushServerURL = URL.knownGood("http://localhost:40000/v2")

    /// How many semesters back the relabel sweep walks when display-toggle
    /// settings change. NTUST keeps ~2 active semesters in flight; 4 covers
    /// the full visible window (current + 3 prior) without scanning archives.
    static let cachedSemesterRelabelDepth = 4

    /// Slack added to a scenario boundary deadline before re-resolving the
    /// Live Activity, so the timer fires after the boundary instant rather
    /// than racing against it. Keeps `time >= slot.start` checks stable.
    static let scenarioBoundarySlackSeconds: TimeInterval = 1

    enum UserDefaultsKeys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let appHasBeenInstalled = "appHasBeenInstalled"
        static let accentColorHex = "accentColorHex"
        static let rememberAnnouncementFilter = "rememberAnnouncementFilter"
        static let savedAnnouncementDepartments = "savedAnnouncementDepartments"
        static let browserPreference = "browserPreference"
        static let showAbsoluteAssignmentTime = "showAbsoluteAssignmentTime"
        static let configuredTabs = "configuredTabs"
        static let macConfiguredTabs = "macConfiguredTabs"
        static let invertSliderDirection = "invertSliderDirection"
        static let libraryFeatureEnabled = "libraryFeatureEnabled"
        static let homeSectionLayout = "homeSectionLayout"
        static let visualPreset = "visualPreset"

        // MARK: Live Activity / reminders
        static let assignmentReminderOffsets = "assignmentReminderOffsets"
        static let isLiveActivityEnabled = "isLiveActivityEnabled"
        static let assignmentLiveActivityLeadTime = "assignmentLiveActivityLeadTime"
        static let classPreparingLeadTime = "classPreparingLeadTime"
        static let showAssignmentScenario = "showAssignmentScenario"
        static let showClassPreparingScenario = "showClassPreparingScenario"
        static let showInClassScenario = "showInClassScenario"
        static let ssoLoginTimestamp = "ssoLoginTimestamp"
        static let classTableSelectedSemester = "classTableSelectedSemester"
        static let homeAssignmentFilter = "homeAssignmentFilter"

        // MARK: Push server
        static let pushServerEnabled = "pushServerEnabled"
        static let pushServerURLOverride = "pushServerURLOverride"
        static let pushLastRegistrationAt = "pushLastRegistrationAt"
        static let pushLastSyncAt = "pushLastSyncAt"

        // MARK: Bulletins
        static let bulletinReadIds = "bulletinReadIds"

        // MARK: Language & Abbreviations
        static let appLanguage = "appLanguage"
        static let useEnglishCourseAbbreviation = "useEnglishCourseAbbreviation"
        static let useEnglishClassroomAbbreviation = "useEnglishClassroomAbbreviation"
        static let classroomMandarinDisplay = "classroomMandarinDisplay"
    }

    enum Periods {
        static let defaultVisible = ["1", "2", "3", "4", "6", "7", "8", "9"]
        static let extended = ["5", "10", "A", "B", "C", "D"]
        /// Chronological order of all periods (for sorting)
        static let chronologicalOrder = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "A", "B", "C", "D"]
        static var weekdays: [String] {
            [
                String(localized: "weekday_mon_short"),
                String(localized: "weekday_tue_short"),
                String(localized: "weekday_wed_short"),
                String(localized: "weekday_thu_short"),
                String(localized: "weekday_fri_short"),
            ]
        }
        static var weekendDays: [String] {
            [
                String(localized: "weekday_sat_short"),
                String(localized: "weekday_sun_short"),
            ]
        }
    }

    enum PeriodTimes {
        static let mapping: [String: (start: String, end: String)] = [
            "1": ("08:10", "09:00"),
            "2": ("09:10", "10:00"),
            "3": ("10:20", "11:10"),
            "4": ("11:20", "12:10"),
            "5": ("12:20", "13:10"),
            "6": ("13:20", "14:10"),
            "7": ("14:20", "15:10"),
            "8": ("15:30", "16:20"),
            "9": ("16:30", "17:20"),
            "10": ("17:30", "18:20"),
            "A": ("18:30", "19:20"),
            "B": ("19:25", "20:15"),
            "C": ("20:15", "21:05"),
            "D": ("21:10", "22:00"),
        ]
    }
}
