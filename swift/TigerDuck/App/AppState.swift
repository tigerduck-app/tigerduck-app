import SwiftUI
import SwiftData
import Defaults

enum BrowserPreference: String, CaseIterable {
    case system
    case inApp
}

@Observable
final class AppState {
    var hasCompletedOnboarding = Defaults[.hasCompletedOnboarding]

    /// App-level presenter flag for the NTUST login sheet. Owned by
    /// ``AppState`` so Home, Class Table, and Settings can all request the
    /// same login flow without each duplicating a local `@State` and a
    /// separate `.sheet` modifier.
    var isShowingNTUSTLoginSheet = false

    let authService = AuthService()
    let sessionManager = NTUSTSessionManager.shared

    // MARK: - Fresh Install Keychain Cleanup

    /// Keychain persists across app uninstall/reinstall on iOS.
    /// Detect fresh install (no UserDefaults marker) and clear stale Keychain data
    /// so the app doesn't start with orphaned credentials from a previous install.
    init() {
        if !Defaults[.appHasBeenInstalled] {
            // Fresh install — purge any leftover Keychain items
            KeychainManager.delete(key: AppConstants.KeychainKeys.studentId)
            KeychainManager.delete(key: AppConstants.KeychainKeys.password)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryToken)
            KeychainManager.delete(key: AppConstants.KeychainKeys.libraryTokenExpiry)
            KeychainManager.delete(key: AppConstants.KeychainKeys.moodleToken)
            KeychainManager.delete(key: AppConstants.KeychainKeys.moodlePrivateToken)
            Defaults[.appHasBeenInstalled] = true
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

        runPendingMigrations()
    }

    // MARK: - Migrations

    /// Trigger all pending one-time compatibility migrations.
    /// Called once per app launch from init(). Runs in a detached background
    /// task so it never blocks the main thread or app startup.
    func runPendingMigrations() {
        Task.detached(priority: .utility) {
            await MoodleTokenMigration.runIfNeeded()
            // Add future migrations here in sequence.
        }
    }

    deinit {
        pendingRefreshTask?.cancel()
        boundaryRefreshTask?.cancel()
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
    private let timelineResolver = CourseTimelineResolver()
    private let courseProvider = CanonicalCourseProvider()
    private var liveActivityObserver: Any?
    private var preferencesObserver: Any?
    private var pendingRefreshTask: Task<Void, Never>?
    private var boundaryRefreshTask: Task<Void, Never>?

    var isNTUSTLoggedIn: Bool { authService.isNTUSTAuthenticated }

    /// Canonical gating decision for 校務系統-protected surfaces. Protected
    /// screens render this state instead of re-deriving from
    /// ``isNTUSTLoggedIn``. The difference matters: ``isNTUSTLoggedIn``
    /// flips to `false` the moment session cookies TTL, even when the
    /// keychain still holds credentials and the next fetch will silently
    /// re-authenticate. Gating on ``hasStoredCredentials`` implements the
    /// cached-first UX — cached content keeps rendering during a silent
    /// re-auth, and the interactive login prompt is reserved for users
    /// who truly have nothing stored.
    func ntustProtectedAccessState(isEmpty: Bool) -> NTUSTProtectedAccessState {
        if !authService.hasStoredCredentials { return .loginRequired }
        return isEmpty ? .empty : .content
    }

    /// Pass-through so views can surface silent re-auth failures without
    /// reaching into ``authService`` directly.
    var ntustReauthErrorMessage: String? { authService.reauthErrorMessage }

    func clearNTUSTReauthError() {
        authService.clearReauthError()
    }

    /// Entry point for any surface that wants to funnel the user into the
    /// NTUST SSO login flow. Idempotent — repeated calls while the sheet is
    /// already up no-op.
    func presentNTUSTLogin() {
        guard !isShowingNTUSTLoginSheet else { return }
        isShowingNTUSTLoginSheet = true
    }

    func dismissNTUSTLogin() {
        isShowingNTUSTLoginSheet = false
    }

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

    /// Full NTUST logout: cancel any in-flight background sync, invalidate
    /// credentials, tear down the Live Activity, cancel pending assignment
    /// reminders, and purge user-scoped caches so a subsequent login (possibly
    /// a different user) never inherits previous state on the lock screen or
    /// in notifications.
    ///
    /// `syncTask` is cancelled first so that `KMPServiceBridge` and the
    /// `backgroundSync` finalize block — both of which check
    /// `Task.isCancelled` before writing — abort cleanly rather than racing
    /// the cache purge below and resurrecting the previous user's data.
    func logoutNTUST() {
        syncTask?.cancel()
        syncTask = nil
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        boundaryRefreshTask?.cancel()
        boundaryRefreshTask = nil

        authService.logout()
        DataCache.shared.clearUserScopedData()
        Task { @MainActor in
            await liveActivityCoordinator.endAll()
            await reminderScheduler.cancelAllOwnedRequests()
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        }
    }

    func notifyLibraryStateChanged() {
        _libraryRevision += 1
    }

    // MARK: - Theme

    /// Accent color hex stored as Int (default system blue 0x007AFF)
    var accentColorHex: Int = Defaults[.accentColorHex] {
        didSet {
            Defaults[.accentColorHex] = accentColorHex
            // Accent color only affects the Live Activity snapshot — reminder
            // notifications are content-identical, so skip rescheduling to
            // avoid thrashing UNUserNotificationCenter on slider drags.
            scheduleLiveActivityRefresh(rescheduleReminderNotifications: false)
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
    var rememberAnnouncementFilter: Bool = Defaults[.rememberAnnouncementFilter] {
        didSet { Defaults[.rememberAnnouncementFilter] = rememberAnnouncementFilter }
    }

    /// Saved announcement filter departments (JSON array)
    var savedAnnouncementDepartments: Set<String> {
        get {
            guard let data = Defaults[.savedAnnouncementDepartmentsData],
                  let arr = try? JSONDecoder().decode([String].self, from: data) else { return [] }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)) {
                Defaults[.savedAnnouncementDepartmentsData] = data
            } else {
                Defaults[.savedAnnouncementDepartmentsData] = nil
            }
        }
    }

    /// Browser preference for opening links
    var browserPreference: BrowserPreference = Defaults[.browserPreference] {
        didSet { Defaults[.browserPreference] = browserPreference }
    }

    /// Invert slider scroll direction: false = natural scroll (drag right → past), true = reversed
    var invertSliderDirection: Bool = Defaults[.invertSliderDirection] {
        didSet { Defaults[.invertSliderDirection] = invertSliderDirection }
    }

    /// Assignment time display: true = absolute (2026/3/24 23:59:00), false = relative (5 天後)
    var showAbsoluteAssignmentTime: Bool = Defaults[.showAbsoluteAssignmentTime] {
        didSet { Defaults[.showAbsoluteAssignmentTime] = showAbsoluteAssignmentTime }
    }

    /// Whether library-related features are enabled (requires explicit user consent)
    var libraryFeatureEnabled: Bool = Defaults[.libraryFeatureEnabled] {
        didSet { Defaults[.libraryFeatureEnabled] = libraryFeatureEnabled }
    }

    /// User-selected visual preset controlling presentation-layer decisions
    /// (card surfaces, accent usage, slider color prominence, etc). This is
    /// a pure UI concern — changes MUST NOT trigger Live Activity refreshes,
    /// reminder reschedules, or notification authorization prompts.
    var visualPreset: VisualPreset = Defaults[.visualPreset] {
        didSet { Defaults[.visualPreset] = visualPreset }
    }

    /// Resolved presentation policy for the current preset. Views read
    /// from this instead of switching on ``visualPreset`` directly, so
    /// adding new presets stays contained to ``VisualStylePolicy``.
    var visualStylePolicy: VisualStylePolicy {
        VisualStylePolicy(preset: visualPreset)
    }

    // MARK: - Tab Configuration

    var configuredTabs: [AppFeature] = {
        if let data = Defaults[.configuredTabsData],
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            let features = rawValues.compactMap { AppFeature(rawValue: $0) }
            return features.isEmpty ? AppFeature.defaultTabs : features
        }
        return AppFeature.defaultTabs
    }() {
        didSet {
            if let data = try? JSONEncoder().encode(configuredTabs.map(\.rawValue)) {
                Defaults[.configuredTabsData] = data
            } else {
                Defaults[.configuredTabsData] = nil
            }
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Defaults[.hasCompletedOnboarding] = true
        backgroundSync()
    }

    // MARK: - Live Activity / reminder refresh

    /// Recomputes the scenario and pushes it to the coordinator. Safe to call
    /// frequently — the coordinator only issues ActivityKit calls when the
    /// snapshot actually changes.
    func refreshLiveActivity() async {
        let now = Date()
        let courses = courseProvider.currentCourses()
        let assignments = DataCache.shared.loadAssignments()
        let snapshot = scenarioResolver.resolve(
            courses: courses,
            assignments: assignments,
            preferences: liveActivityPreferences,
            accentHex: accentColorHex,
            now: now
        )
        await liveActivityCoordinator.apply(snapshot: snapshot)
        scheduleBoundaryRefresh(
            snapshot: snapshot,
            courses: courses,
            assignments: assignments,
            now: now
        )
    }

    /// While the app is in the foreground, fire a one-shot refresh as soon as
    /// the next meaningful scenario boundary elapses so the Live Activity does
    /// not sit on a stale scenario. When the app is backgrounded the Task is
    /// suspended by iOS; `scenePhase == .active` on return triggers another
    /// refresh, which reschedules this task. This is a best-effort foreground
    /// improvement — true background correctness needs push updates.
    private func scheduleBoundaryRefresh(
        snapshot: LiveActivitySnapshot?,
        courses: [SDCourse],
        assignments: [SDAssignment],
        now: Date
    ) {
        boundaryRefreshTask?.cancel()
        guard let boundary = nextScenarioBoundary(
            snapshot: snapshot,
            courses: courses,
            assignments: assignments,
            now: now
        ) else { return }
        let delay = boundary.timeIntervalSince(now) + 1
        guard delay > 0 else { return }
        boundaryRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.refreshLiveActivity()
        }
    }

    private func nextScenarioBoundary(
        snapshot: LiveActivitySnapshot?,
        courses: [SDCourse],
        assignments: [SDAssignment],
        now: Date
    ) -> Date? {
        var candidates: [Date] = []

        if let target = snapshot?.countdownTarget {
            candidates.append(target)
        }

        let classPrep = liveActivityPreferences.classPreparingLeadTime
        if let nextClassStart = timelineResolver
            .timeline(for: courses, around: now)
            .filter({ $0.start > now })
            .min(by: { $0.start < $1.start })?.start {
            candidates.append(nextClassStart.addingTimeInterval(-classPrep))
            candidates.append(nextClassStart)
        }

        let assignmentLead = liveActivityPreferences.assignmentLiveActivityLeadTime
        if let nextDue = assignments
            .filter({ !$0.isCompleted && $0.dueDate > now })
            .min(by: { $0.dueDate < $1.dueDate })?.dueDate {
            candidates.append(nextDue.addingTimeInterval(-assignmentLead))
            candidates.append(nextDue)
        }

        return candidates.filter { $0 > now }.min()
    }

    /// Rebuilds all reminder notifications from the current cached assignments
    /// and the user's selected offsets. The scheduler silently no-ops when
    /// notifications are not authorized, so this never triggers a permission
    /// prompt — call `requestNotificationAuthorization()` from explicit user
    /// intent instead (e.g. when the notifications settings page appears).
    func rescheduleReminders() async {
        let assignments = DataCache.shared.loadAssignments()
        await reminderScheduler.reschedule(
            assignments: assignments,
            offsets: liveActivityPreferences.assignmentReminderOffsets
        )
    }

    /// Prompts the user for notification authorization when, and only when,
    /// they reach an explicit notification-related entry point. After a fresh
    /// grant, immediately rebuild the reminder schedule so the toggles the
    /// user just saw take effect.
    func requestNotificationAuthorization() async {
        let granted = await reminderScheduler.requestAuthorizationIfNeeded()
        if granted {
            await rescheduleReminders()
        }
    }

    /// Debounces multiple change events (e.g. slider drags or quick toggles)
    /// into a single refresh pass so the scheduler is not thrashed.
    ///
    /// - Parameter rescheduleReminderNotifications: pass `false` when the
    ///   trigger only affects the Live Activity snapshot (e.g. accent color).
    ///   Reminder notifications carry only title / course / due date, so
    ///   re-enqueuing them for visual-only changes does no user-visible work
    ///   and just thrashes `UNUserNotificationCenter`.
    private func scheduleLiveActivityRefresh(rescheduleReminderNotifications: Bool = true) {
        pendingRefreshTask?.cancel()
        pendingRefreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await refreshLiveActivity()
            if rescheduleReminderNotifications {
                await rescheduleReminders()
            }
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
            // Bail out before persisting if logout cancelled this sync while
            // the network calls were in flight. Without the guard the merged
            // calendar would be written back on top of a freshly purged cache
            // and the previous user's events would resurface.
            guard !Task.isCancelled else { return }

            var calendarCache = DataCache.shared.loadCalendarEvents()
            calendarCache.removeAll { $0.source == .school || $0.source == .moodle }
            calendarCache.append(contentsOf: fetchedSchoolEvents)
            calendarCache.append(contentsOf: moodleEvents)
            DataCache.shared.saveCalendarEvents(calendarCache)

            await MainActor.run {
                guard !Task.isCancelled else { return }
                sessionManager.loadingState = .loaded
                NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            }
        }
    }
}
