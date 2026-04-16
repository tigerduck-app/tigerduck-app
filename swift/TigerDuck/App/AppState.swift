import SwiftUI
import SwiftData

enum BrowserPreference: String, CaseIterable {
    case system
    case inApp
}

@Observable
final class AppState {
    var hasCompletedOnboarding = UserDefaults.standard.bool(forKey: AppConstants.UserDefaultsKeys.hasCompletedOnboarding)

    let authService = AuthService()
    let sessionManager = NTUSTSessionManager.shared

    // MARK: - Fresh Install Keychain Cleanup

    /// Keychain persists across app uninstall/reinstall on iOS.
    /// Detect fresh install (no UserDefaults marker) and clear stale Keychain data
    /// so the app doesn't start with orphaned credentials from a previous install.
    init() {
        let key = AppConstants.UserDefaultsKeys.appHasBeenInstalled
        if !UserDefaults.standard.bool(forKey: key) {
            // Fresh install — purge any leftover Keychain items
            KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
            KeychainManager.delete(key: AppConstants.KeychainKeys.password)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryToken)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryTokenExpiry)
            UserDefaults.standard.set(true, forKey: key)
        }

        liveActivityObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.dataDidUpdate,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLiveActivityRefresh()
        }

        preferencesObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.liveActivityPreferencesDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLiveActivityRefresh()
        }
    }

    deinit {
        pendingRefreshTask?.cancel()
        if let observer = liveActivityObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = preferencesObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private var _libraryRevision = 0
    private var syncTask: Task<Void, Never>?

    // MARK: - Live Activity

    let liveActivityPreferences = LiveActivityPreferencesStore()
    private let liveActivityCoordinator = LiveActivityCoordinator()
    private let reminderScheduler = AssignmentReminderScheduler()
    private let scenarioResolver = LiveActivityScenarioResolver()
    private let courseProvider = CanonicalCourseProvider()
    private var liveActivityObserver: Any?
    private var preferencesObserver: Any?
    private var pendingRefreshTask: Task<Void, Never>?

    var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }

    var isLibraryLoggedIn: Bool {
        _ = _libraryRevision
        return LibraryService.isTokenValid
    }

    var libraryUsername: String? {
        _ = _libraryRevision
        return LibraryService.storedUsername
    }

    func logoutLibrary() {
        LibraryService.clearCredentials()
        _libraryRevision += 1
    }

    func notifyLibraryStateChanged() {
        _libraryRevision += 1
    }

    // MARK: - Theme

    /// Accent color hex stored as Int (default system blue 0x007AFF)
    var accentColorHex: Int = UserDefaults.standard.object(forKey: AppConstants.UserDefaultsKeys.accentColorHex) as? Int ?? 0x007AFF {
        didSet {
            UserDefaults.standard.set(accentColorHex, forKey: AppConstants.UserDefaultsKeys.accentColorHex)
            scheduleLiveActivityRefresh()
        }
    }

    var accentColor: Color {
        Color(hex: UInt(accentColorHex))
    }

    static let themeColors: [(name: String, hex: Int)] = [
        ("藍", 0x007AFF),
        ("紫", 0xAF52DE),
        ("粉", 0xFF2D55),
        ("紅", 0xFF3B30),
        ("橘", 0xFF9500),
        ("綠", 0x34C759),
        ("青", 0x5AC8FA),
        ("靛", 0x5856D6),
    ]

    // MARK: - Settings

    /// Whether to persist announcement filter selection across sessions
    var rememberAnnouncementFilter: Bool = UserDefaults.standard.bool(forKey: AppConstants.UserDefaultsKeys.rememberAnnouncementFilter) {
        didSet { UserDefaults.standard.set(rememberAnnouncementFilter, forKey: AppConstants.UserDefaultsKeys.rememberAnnouncementFilter) }
    }

    /// Saved announcement filter departments (JSON array)
    var savedAnnouncementDepartments: Set<String> {
        get {
            guard let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKeys.savedAnnouncementDepartments),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                UserDefaults.standard.set(data, forKey: AppConstants.UserDefaultsKeys.savedAnnouncementDepartments)
            }
        }
    }

    /// Browser preference for opening links
    var browserPreference: BrowserPreference = {
        if let raw = UserDefaults.standard.string(forKey: AppConstants.UserDefaultsKeys.browserPreference),
           let pref = BrowserPreference(rawValue: raw) {
            return pref
        }
        return .system
    }() {
        didSet { UserDefaults.standard.set(browserPreference.rawValue, forKey: AppConstants.UserDefaultsKeys.browserPreference) }
    }

    /// Time slider style preference
    var timeSliderStyle: TimeSliderStyle = {
        if let raw = UserDefaults.standard.string(forKey: AppConstants.UserDefaultsKeys.timeSliderStyle),
           let style = TimeSliderStyle(rawValue: raw) {
            return style
        }
        return .fluidTrack
    }() {
        didSet { UserDefaults.standard.set(timeSliderStyle.rawValue, forKey: AppConstants.UserDefaultsKeys.timeSliderStyle) }
    }

    /// Invert slider scroll direction: false = natural scroll (drag right → past), true = reversed
    var invertSliderDirection: Bool = UserDefaults.standard.bool(forKey: AppConstants.UserDefaultsKeys.invertSliderDirection) {
        didSet { UserDefaults.standard.set(invertSliderDirection, forKey: AppConstants.UserDefaultsKeys.invertSliderDirection) }
    }

    /// Assignment time display: true = absolute (2026/3/24 23:59:00), false = relative (5 天後)
    var showAbsoluteAssignmentTime: Bool = UserDefaults.standard.bool(forKey: AppConstants.UserDefaultsKeys.showAbsoluteAssignmentTime) {
        didSet { UserDefaults.standard.set(showAbsoluteAssignmentTime, forKey: AppConstants.UserDefaultsKeys.showAbsoluteAssignmentTime) }
    }

    /// Whether library-related features are enabled (requires explicit user consent)
    var libraryFeatureEnabled: Bool = UserDefaults.standard.bool(forKey: AppConstants.UserDefaultsKeys.libraryFeatureEnabled) {
        didSet { UserDefaults.standard.set(libraryFeatureEnabled, forKey: AppConstants.UserDefaultsKeys.libraryFeatureEnabled) }
    }

    // MARK: - Tab Configuration

    var configuredTabs: [AppFeature] = {
        if let data = UserDefaults.standard.data(forKey: AppConstants.UserDefaultsKeys.configuredTabs),
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            let features = rawValues.compactMap { AppFeature(rawValue: $0) }
            return features.isEmpty ? AppFeature.defaultTabs : features
        }
        return AppFeature.defaultTabs
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(configuredTabs.map(\.rawValue)) {
                UserDefaults.standard.set(data, forKey: AppConstants.UserDefaultsKeys.configuredTabs)
            }
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: AppConstants.UserDefaultsKeys.hasCompletedOnboarding)
        backgroundSync()
    }

    // MARK: - Live Activity / reminder refresh

    /// Recomputes the scenario and pushes it to the coordinator. Safe to call
    /// frequently — the coordinator only issues ActivityKit calls when the
    /// snapshot actually changes.
    func refreshLiveActivity() async {
        let courses = courseProvider.currentCourses()
        let assignments = DataCache.shared.loadAssignments()
        let snapshot = scenarioResolver.resolve(
            courses: courses,
            assignments: assignments,
            preferences: liveActivityPreferences,
            accentHex: accentColorHex
        )
        await liveActivityCoordinator.apply(snapshot: snapshot)
    }

    /// Rebuilds all reminder notifications from the current cached assignments
    /// and the user's selected offsets.
    func rescheduleReminders() async {
        let assignments = DataCache.shared.loadAssignments()
        await reminderScheduler.reschedule(
            assignments: assignments,
            offsets: liveActivityPreferences.assignmentReminderOffsets
        )
    }

    /// Debounces multiple change events (e.g. slider drags or quick toggles)
    /// into a single refresh pass so the scheduler is not thrashed.
    private func scheduleLiveActivityRefresh() {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshLiveActivity()
            await rescheduleReminders()
        }
    }

    /// Background sync all data on app launch
    func backgroundSync() {
        guard hasCompletedOnboarding else { return }
        syncTask?.cancel()
        syncTask = Task {
            guard NetworkMonitor.shared.isConnected else {
                await MainActor.run {
                    sessionManager.loadingState = .error("無網路連線")
                }
                return
            }

            sessionManager.loadingState = .loading

            // Authenticate once upfront so parallel tasks reuse the SSO session
            let isAuthenticated = await authService.ensureAuthenticated()

            // School events are public — always fetch. Courses/assignments need auth.
            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            let fetchedAssignments: [SDAssignment]
            if isAuthenticated {
                async let coursesTask = KMPServiceBridge.fetchCourses(authService: authService)
                async let assignmentsTask = KMPServiceBridge.fetchAssignments(authService: authService)
                (_, fetchedAssignments) = await (coursesTask, assignmentsTask)
            } else {
                fetchedAssignments = DataCache.shared.loadAssignments()
            }
            let fetchedSchoolEvents = await schoolEventsTask

            // Build moodle calendar events from assignments and merge with school events
            let moodleEvents = fetchedAssignments.map {
                SDCalendarEvent(eventId: "moodle-\($0.assignmentId)", title: $0.title, date: $0.dueDate, source: .moodle)
            }
            var calendarCache = DataCache.shared.loadCalendarEvents()
            calendarCache.removeAll { $0.source == .school || $0.source == .moodle }
            calendarCache.append(contentsOf: fetchedSchoolEvents)
            calendarCache.append(contentsOf: moodleEvents)
            DataCache.shared.saveCalendarEvents(calendarCache)

            await MainActor.run {
                sessionManager.loadingState = .loaded
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
        }
    }
}
