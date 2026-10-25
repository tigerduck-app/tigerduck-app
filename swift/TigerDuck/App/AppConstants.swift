import Foundation

extension URL {
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

    static let taipeiTimeZone: TimeZone = TimeZone(identifier: "Asia/Taipei") ?? .current

    static let taipeiCalendar: Calendar = {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = taipeiTimeZone
        return cal
    }()

    static let dataDidUpdate = Notification.Name("TigerDuck.dataDidUpdate")
    static let liveActivityPreferencesDidChange = Notification.Name("TigerDuck.liveActivityPreferencesDidChange")
    ///
    static let liveActivityPreferencesRemoteOriginKey = "TigerDuck.liveActivityPreferencesRemoteOrigin"
    static let liveActivityPreferencesDeviceOnlyKey = "TigerDuck.liveActivityPreferencesDeviceOnly"
    static let languageDidChange = Notification.Name("TigerDuck.languageDidChange")
    static let courseSkipStateDidChange = Notification.Name("TigerDuck.courseSkipStateDidChange")
    static let holidayNotifyDidChange = Notification.Name("TigerDuck.holidayNotifyDidChange")
    static let courseColorMapDidChange = Notification.Name("TigerDuck.courseColorMapDidChange")
    static let accentColorDidChange = Notification.Name("TigerDuck.accentColorDidChange")
    static let tlsPinAcceptanceDidChange = Notification.Name("TigerDuck.tlsPinAcceptanceDidChange")
    static let moodleBaseURL = URL.knownGood("https://moodle2.ntust.edu.tw")

    /// Wraps a site-relative Moodle path in the envelope the Moodle Mobile app
    /// expects: `moodlemobile://<site-url>?redirect=<path>`.
    /// Built by string: `URLComponents` cannot put a site URL in the authority. With
    /// `host = "https"` and `path = "//<host>"` it gives `moodlemobile://https//<host>`,
    /// dropping the inner scheme's colon so the app cannot parse a site; `host = "https:"`
    /// makes `url` nil. `=`, `&` and `+` are escaped so a multi-parameter target stays in
    /// the single `redirect` value. Matches Android's `Assignment.moodleDeepLink`.
    static func moodleDeepLink(redirectingTo path: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "=&+")
        guard let escaped = path.addingPercentEncoding(withAllowedCharacters: allowed) else {
            return nil
        }
        let host = moodleBaseURL.host ?? "moodle2.ntust.edu.tw"
        return URL(string: "moodlemobile://https://\(host)?redirect=\(escaped)")
    }

    nonisolated enum KeychainKeys {
        static let studentId = "ntust_student_id"
        static let password = "ntust_password"
        static let libraryUsername = "library_username"
        static let libraryPassword = "library_password"
        static let libraryToken = "library_token"
        static let libraryTokenExpiry = "library_token_expiry"
        static let moodleToken = "moodle_token"
        static let moodlePrivateToken = "moodle_private_token"
        static let pushDeviceId = "push_device_id"
    }

    static let productionPushServerURL = URL.knownGood("https://api.tigerduck.app/v3")

    static let cachedSemesterRelabelDepth = 4

    /// How deep the app follows HTML nesting: far deeper than mail or Moodle nests, and short of
    /// the depth where WebKit stops nesting elements, so the tree `MailReadableHTML` reads is the
    static let maximumHTMLDepth = 256

    static let scenarioBoundarySlackSeconds: TimeInterval = 1

    enum UserDefaultsKeys {
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let appHasBeenInstalled = "appHasBeenInstalled"
        static let accentColorHex = "accentColorHex"
        static let browserPreference = "browserPreference"
        static let browserAddressBar = "browserAddressBar"
        static let macMoodleOpenTarget = "macMoodleOpenTarget"
        static let showAbsoluteAssignmentTime = "showAbsoluteAssignmentTime"
        static let alwaysShowAllPeriods = "alwaysShowPeriodsABC"
        static let showClassroomInClassTable = "showClassroomInClassTable"
        static let pinTodayCoursesOnClassTable = "pinTodayCoursesOnClassTable"
        static let outlineRequiredCourses = "outlineRequiredCourses"
        static let configuredTabs = "configuredTabs"
        static let macConfiguredTabs = "macConfiguredTabs"
        static let invertSliderDirection = "invertSliderDirection"
        static let flipToLibraryEnabled = "flipToLibraryEnabled"
        static let courseCardFontScale = "courseCardFontScaleV2"
        static let homeSectionLayout = "homeSectionLayout"
        static let visualPreset = "visualPreset"

        static let assignmentReminderOffsets = "assignmentReminderOffsets"
        static let isAssignmentReminderEnabled = "isAssignmentReminderEnabled"
        static let isClassReminderEnabled = "isClassReminderEnabled"
        static let classReminderLeadMinutes = "classReminderLeadMinutes"
        static let hasPickedClassReminderLead = "hasPickedClassReminderLead"
        static let isLiveActivityEnabled = "isLiveActivityEnabled"
        static let assignmentLiveActivityLeadTime = "assignmentLiveActivityLeadTime"
        static let classPreparingLeadTime = "classPreparingLeadTime"
        static let showAssignmentScenario = "showAssignmentScenario"
        static let showClassPreparingScenario = "showClassPreparingScenario"
        static let showInClassScenario = "showInClassScenario"
        static let ssoLoginTimestamp = "ssoLoginTimestamp"
        static let classTableSelectedSemester = "classTableSelectedSemester"
        static let homeAssignmentFilter = "homeAssignmentFilter"

        static let cloudSyncEnabled = "cloudSyncEnabled"
        static let notificationSettingsPushPending = "notificationSettingsPushPending"

        static let pushServerEnabled = "pushServerEnabled"
        static let bulletinPushEnabled = "bulletinPushEnabled"
        static let pushServerURLOverride = "pushServerURLOverride"
        static let serverPushUserOptOut = "serverPushUserOptOut"
        static let shownServerPopupIds = "shownServerPopupIds"

        static let bulletinReadIds = "bulletinReadIds"

        static let appLanguage = "appLanguage"
        static let useEnglishCourseAbbreviation = "useEnglishCourseAbbreviation"
        static let useEnglishClassroomAbbreviation = "useEnglishClassroomAbbreviation"
        static let classroomMandarinDisplay = "classroomMandarinDisplay"

        static let skippedUpdateVersion = "skippedUpdateVersion"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
        static let lastReportedUnparseableStoreVersion = "lastReportedUnparseableStoreVersion"
        static let lastPromptedUpdateVersion = "lastPromptedUpdateVersion"
        static let lastPromptedUpdateAt = "lastPromptedUpdateAt"
        static let lastShownWhatsNewVersion = "lastShownWhatsNewVersion"
    }

    static let updateCheckThrottle: TimeInterval = 24 * 60 * 60

    static let updatePromptCooldown: TimeInterval = 7 * 24 * 60 * 60

    /// iTunes Lookup storefront for App Store version checks. Pinned to
    /// the release storefront (Taiwan) so a user traveling abroad or
    /// behind a VPN through an unsupported region doesn't get
    /// `resultCount == 0` (which the coordinator then treats as "no
    /// public record" and masks a real available update). Update if the
    /// app launches in additional storefronts.
    static let appStoreLookupStorefront = "tw"

    enum Periods {
        static let defaultVisible = ["1", "2", "3", "4", "6", "7", "8", "9", "10"]
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

        static func shortWeekdayLabel(_ weekday: Int) -> String {
            let labels = weekdays + weekendDays
            return labels.indices.contains(weekday - 1) ? labels[weekday - 1] : "\(weekday)"
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
            "A": ("18:25", "19:15"),
            "B": ("19:20", "20:10"),
            "C": ("20:15", "21:05"),
            "D": ("21:10", "22:00"),
        ]
    }
}
