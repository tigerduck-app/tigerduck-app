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
            // Fresh install — purge any leftover Keychain items.
            let keysToWipe: [String] = [
                AppConstants.KeychainKeys.studentId,
                AppConstants.KeychainKeys.password,
                AppConstants.KeychainKeys.libraryUsername,
                AppConstants.KeychainKeys.libraryPassword,
                AppConstants.KeychainKeys.libraryToken,
                AppConstants.KeychainKeys.libraryTokenExpiry,
                AppConstants.KeychainKeys.moodleToken,
                AppConstants.KeychainKeys.moodlePrivateToken,
            ]
            let allOk = keysToWipe
                .map { KeychainManager.deleteReportingSuccess(key: $0) }
                .allSatisfy { $0 }
            // Only mark "installed" if every delete succeeded. A partial
            // failure leaves the flag false so the next launch retries —
            // otherwise stale credentials could survive a reinstall.
            if allOk {
                Defaults[.appHasBeenInstalled] = true
            }
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
            self?.requestPushScheduleSync()
        }

        skipStateObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.courseSkipStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLiveActivityRefresh()
        }

        runPendingMigrations()

        liveActivityCoordinator.setUpdateTokenRegistrationHandler { [weak self] registration in
            await self?.pushCoordinator.registerLiveActivityUpdateToken(registration)
        }

        // Auto-enable the push stack when the user has already opted in
        // (e.g. across app launches). The coordinator no-ops when the
        // toggle is off, so this is safe to call unconditionally.
        pushCoordinator.enable()

        // Apply a stored in-app language override on launch so string lookups
        // use the user's chosen locale. Skip when "system" — calling apply()
        // there would removeObject(AppleLanguages), wiping the per-app override
        // iOS Settings writes to that same key.
        if appLanguage != LanguageManager.system {
            LanguageManager.apply(appLanguage)
        }
    }

    // MARK: - Migrations

    /// Trigger all pending one-time compatibility migrations.
    /// Called once per app launch from init(). Runs in a detached background
    /// task so it never blocks the main thread or app startup.
    func runPendingMigrations() {
        Task(priority: .utility) { @MainActor in
            await MoodleTokenMigration.runIfNeeded()
            HomeSectionTitleMigration.runIfNeeded()
            ClassroomAbbrCacheMigration.runIfNeeded()
            CustomNameCacheMigration.runIfNeeded()
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
        if let observer = skipStateObserver {
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
    private var skipStateObserver: Any?
    private var pendingRefreshTask: Task<Void, Never>?
    private var boundaryRefreshTask: Task<Void, Never>?
    private var relabelTask: Task<Void, Never>?

    // MARK: - Push server

    let pushCoordinator = PushCoordinator()

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
    /// `syncTask` is cancelled first so that `AppServiceBridge` and the
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
        // Use bitPattern to avoid trapping on a corrupted-defaults negative
        // accentColorHex (Int → UInt conversion crashes on negative values).
        Color(hex: UInt(bitPattern: Int(accentColorHex)))
    }

    static let themeColors: [(nameKey: String, hex: Int)] = [
        ("color_name_blue", 0x007AFF),
        ("color_name_purple", 0xAF52DE),
        ("color_name_pink", 0xFF2D55),
        ("color_name_red", 0xFF3B30),
        ("color_name_orange", 0xFF9500),
        ("color_name_green", 0x34C759),
        ("color_name_cyan", 0x5AC8FA),
        ("color_name_indigo", 0x5856D6),
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
            do {
                let data = try JSONEncoder().encode(Array(newValue))
                Defaults[.savedAnnouncementDepartmentsData] = data
            } catch {
                AppLogger.captureError(error, context: ["phase": "savedAnnouncementDepartments.encode"])
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

    // MARK: - Language & Abbreviations

    /// BCP-47 language tag, or "system" to follow device locale.
    /// Writing this applies the change immediately via LanguageManager.apply()
    /// and posts languageDidChange so TigerDuckApp can swap the root-view ID.
    var appLanguage: String = Defaults[.appLanguage] {
        didSet {
            guard appLanguage != oldValue else { return }
            // Cancel any in-flight sync started under the previous locale.
            // AppServiceBridge.fetchCourses snapshots the language at task
            // start, so without this an orphaned task could land after the
            // post-language-change refresh and overwrite DataCache with
            // previous-locale names.
            syncTask?.cancel()
            syncTask = nil
            Defaults[.appLanguage] = appLanguage
            LanguageManager.apply(appLanguage)
            AppServiceBridge.handleLanguageChange()
            NotificationCenter.default.post(name: AppConstants.languageDidChange, object: nil)
        }
    }

    var useEnglishCourseAbbreviation: Bool = Defaults[.useEnglishCourseAbbreviation] {
        didSet {
            guard useEnglishCourseAbbreviation != oldValue else { return }
            Defaults[.useEnglishCourseAbbreviation] = useEnglishCourseAbbreviation
            relabelAllCachedCourses()
        }
    }

    var useEnglishClassroomAbbreviation: Bool = Defaults[.useEnglishClassroomAbbreviation] {
        didSet {
            guard useEnglishClassroomAbbreviation != oldValue else { return }
            Defaults[.useEnglishClassroomAbbreviation] = useEnglishClassroomAbbreviation
            relabelAllCachedCourses()
        }
    }

    /// One of "original", "pinyin", "translated"
    var classroomMandarinDisplay: String = Defaults[.classroomMandarinDisplay] {
        didSet {
            guard classroomMandarinDisplay != oldValue else { return }
            let valid: Set<String> = ["original", "pinyin", "translated"]
            // Reject invalid input by reassigning; the recursive didSet then
            // takes the valid branch and persists once. Returning here keeps
            // this outer call from also calling relabelAllCachedCourses.
            if !valid.contains(classroomMandarinDisplay) {
                classroomMandarinDisplay = "original"
                return
            }
            Defaults[.classroomMandarinDisplay] = classroomMandarinDisplay
            relabelAllCachedCourses()
        }
    }

    /// Re-derive course/classroom labels for every cached semester using the
    /// current toggle settings, then post `dataDidUpdate` so visible views
    /// reload from the freshly relabeled cache. Lives on `AppState` so the
    /// relabel still runs when no `ClassTableViewModel` is alive (e.g., the
    /// user toggled in Settings without ever opening the Class Table tab).
    ///
    /// Runs on a detached task so disk I/O (up to four cached semesters plus
    /// user-added courses, plus a first-call JSON parse inside
    /// ``NameAbbrService``) does not block the UI thread when the toggle is
    /// flipped from a Settings view. Rapid toggling cancels the previous task
    /// so the latest settings always win the save race.
    private func relabelAllCachedCourses() {
        relabelTask?.cancel()
        relabelTask = Task.detached(priority: .userInitiated) {
            let courseAbbrEnabled = Defaults[.useEnglishCourseAbbreviation]
            let classroomAbbrEnabled = Defaults[.useEnglishClassroomAbbreviation]
            let classroomMandarinDisplay = Defaults[.classroomMandarinDisplay]

            var anyChanged = false
            var code = CourseSelectionService.currentSemesterCode()
            var consecutiveEmpty = 0
            for _ in 0..<AppConstants.cachedSemesterRelabelDepth {
                if Task.isCancelled { return }
                let courses = DataCache.shared.loadCourses(semester: code)
                if courses.isEmpty {
                    consecutiveEmpty += 1
                    // Two empty semesters in a row means we've walked past
                    // any data the user has fetched; further iterations just
                    // hit disk for nothing.
                    if consecutiveEmpty >= 2 { break }
                } else {
                    consecutiveEmpty = 0
                }
                if !courses.isEmpty {
                    let changed = NameAbbrService.shared.relabelInPlace(
                        courses,
                        courseAbbrEnabled: courseAbbrEnabled,
                        classroomAbbrEnabled: classroomAbbrEnabled,
                        classroomMandarinDisplay: classroomMandarinDisplay
                    )
                    if changed {
                        DataCache.shared.saveCourses(courses, semester: code)
                        anyChanged = true
                    }
                }
                code = CourseSelectionService.previousSemesterCode(code)
            }

            // User-added courses live in their own file, outside the per-semester
            // fetch cache, so the loop above never sees them. Relabel separately
            // so manually-added Mandarin classrooms also honor the display toggle.
            if Task.isCancelled { return }
            let userAdded = DataCache.shared.loadUserAddedCourses()
            if !userAdded.isEmpty {
                let changed = NameAbbrService.shared.relabelInPlace(
                    userAdded,
                    courseAbbrEnabled: courseAbbrEnabled,
                    classroomAbbrEnabled: classroomAbbrEnabled,
                    classroomMandarinDisplay: classroomMandarinDisplay
                )
                if changed {
                    DataCache.shared.saveUserAddedCourses(userAdded)
                    anyChanged = true
                }
            }

            if anyChanged && !Task.isCancelled {
                await MainActor.run {
                    NotificationCenter.default.post(
                        name: AppConstants.dataDidUpdate, object: nil
                    )
                }
            }
        }
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
            do {
                let data = try JSONEncoder().encode(configuredTabs.map(\.rawValue))
                Defaults[.configuredTabsData] = data
            } catch {
                // Don't clobber a working persisted value with nil on a
                // (vanishingly rare) encode failure — silently losing the
                // user's customization on next launch is worse than logging.
                AppLogger.captureError(error, context: ["phase": "configuredTabs.encode"])
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
        let delay = boundary.timeIntervalSince(now) + AppConstants.scenarioBoundarySlackSeconds
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
            requestPushScheduleSync()
        }
    }

    // MARK: - Push server integration

    /// Wire the `PushAppDelegate` at app launch so APNs device tokens flow
    /// into `PushRegistrationService`.
    func bindPushDelegate(_ delegate: PushAppDelegate) {
        pushCoordinator.bindTokenForwarding(delegate)
    }

    /// Sync the next-48h event list to the push server. No-ops when the user
    /// has not enabled server push. Safe to call from any scene / data
    /// transition — `PushCoordinator` debounces bursts into a single POST.
    func requestPushScheduleSync() {
        pushCoordinator.requestSync { [weak self] in
            guard let self else {
                return ScheduleSyncService.Inputs(
                    courses: [],
                    assignments: [],
                    accentHex: 0x007AFF,
                    classPreparingLeadTime: 0,
                    assignmentLeadTime: 0,
                    showClassPreparing: false,
                    showInClass: false,
                    showAssignmentScenario: false
                )
            }
            return ScheduleSyncService.Inputs(
                courses: courseProvider.currentCourses(),
                assignments: DataCache.shared.loadAssignments(),
                accentHex: accentColorHex,
                classPreparingLeadTime: liveActivityPreferences.classPreparingLeadTime,
                assignmentLeadTime: liveActivityPreferences.assignmentLiveActivityLeadTime,
                showClassPreparing: liveActivityPreferences.showClassPreparingScenario,
                showInClass: liveActivityPreferences.showInClassScenario,
                showAssignmentScenario: liveActivityPreferences.showAssignmentScenario
            )
        }
    }

    /// Enable server push (registers for remote notifications, starts PTS
    /// relay, queues an immediate sync). Call only from explicit user intent
    /// — turning on the Settings toggle.
    func enablePushServer() {
        Defaults[.pushServerEnabled] = true
        pushCoordinator.enable()
        requestPushScheduleSync()
    }

    /// Disable server push (tells server to drop the device, stops relay).
    func disablePushServer() async {
        Defaults[.pushServerEnabled] = false
        await pushCoordinator.disable()
    }

    /// Background sync all data on app launch.
    ///
    /// Three independent tracks run in parallel. Moodle rides a long-
    /// lived OIDC token (no NTUST SSO dependency), the ICS calendar is
    /// public, and the courses track owns its own auth check so Moodle
    /// and ICS are never held up behind `ensureAuthenticated()`.
    func backgroundSync() {
        guard hasCompletedOnboarding else { return }
        syncTask?.cancel()
        syncTask = Task {
            guard NetworkMonitor.shared.isConnected else {
                await MainActor.run {
                    sessionManager.loadingState = .error(String(localized: "error_network_unavailable"))
                }
                return
            }

            sessionManager.loadingState = .loading

            async let assignmentsTask = AppServiceBridge.fetchAssignments(authService: authService)
            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            async let coursesTask: Bool = syncCoursesIfAuthenticated()

            let fetchedAssignments = await assignmentsTask
            let fetchedSchoolEvents = await schoolEventsTask
            _ = await coursesTask

            // Build moodle calendar events from assignments and merge with school events
            let moodleEvents = fetchedAssignments.map {
                SDCalendarEvent(eventId: "moodle-\($0.assignmentId)", title: $0.displayTitle, date: $0.dueDate, source: .moodle)
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

    /// Runs the NTUST-SSO-authenticated portion of background sync
    /// (course list refresh). Factored out so `backgroundSync` can
    /// launch it via `async let` alongside the independent Moodle and
    /// ICS fetches. Returns the auth result purely so the call site
    /// can use it as an `async let` value.
    private func syncCoursesIfAuthenticated() async -> Bool {
        guard await authService.ensureAuthenticated() else { return false }
        _ = await AppServiceBridge.fetchCourses(authService: authService)
        return true
    }
}
