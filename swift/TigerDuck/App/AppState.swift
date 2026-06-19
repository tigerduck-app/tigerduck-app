import SwiftUI
import SwiftData
import Defaults
import os

@Observable
final class AppState {
    /// Debounced reload channel for widgets when course-name font scale
    /// changes. The slider's stepped binding fires didSet on every step
    /// crossing during a drag (up to 16 across the 0.8–1.6 range), so
    /// routing through the coordinator collapses a fast drag into a
    /// single 300ms-debounced WidgetKit reload instead of saturating
    /// the per-app reload budget.
    private let widgetReloadCoordinator = WidgetReloadCoordinator()

    var hasCompletedOnboarding = Defaults[.hasCompletedOnboarding]

    /// App-level presenter flag for the NTUST login sheet. Owned by
    /// ``AppState`` so Home, Class Table, and Settings can all request the
    /// same login flow without each duplicating a local `@State` and a
    /// separate `.sheet` modifier.
    var isShowingNTUSTLoginSheet = false

    /// Mac-only, intentionally non-persisted: set by `MacLoginView`'s
    /// "Skip for now" button so the user can preview the app without
    /// credentials. Resets on every app launch (so first-launch always
    /// shows the login wall) and on logout (so signing out returns the
    /// user to the login screen rather than stranding them in an
    /// unauthenticated `MacContentView`).
    var didSkipMacLogin = false

    let authService = AuthService()
    let sessionManager = NTUSTSessionManager.shared

    #if os(iOS)
    /// Coordinator owning the iTunes Lookup + What's New plumbing. Lives
    /// on `AppState` (not as a top-level singleton) so SwiftUI views observe
    /// changes through the same `@Environment(AppState.self)` they already
    /// use, and so its sheet-presentation flags reset alongside the rest of
    /// app state on logout / fresh install paths.
    let updateNotifyCoordinator = UpdateNotifyCoordinator()
    #endif

    // MARK: - Fresh Install Keychain Cleanup

    /// Keychain persists across app uninstall/reinstall on iOS.
    /// Detect fresh install (no UserDefaults marker) and clear stale Keychain data
    /// so the app doesn't start with orphaned credentials from a previous install.
    init() {
        #if os(iOS)
        // Build the shared PushIdentity first so both the AuthTokenManager
        // and PushCoordinator use the same stable device UUID.
        let identity = PushIdentity.loadOrCreate()
        let atm = AuthTokenManager(
            baseURL: PushServerConfig.resolveServerURL().absoluteString,
            deviceUUID: identity.uuid
        )
        self.authTokenManager = atm
        self.pushCoordinator = PushCoordinator(
            identity: identity,
            authTokenManager: atm
        )
        #endif

        if !Defaults[.appHasBeenInstalled] {
            #if os(iOS)
            // Stamp the running version as "already shown" so the
            // What's New sheet does NOT fire on the very first launch
            // after install — a freshly downloaded app has no upgrade
            // history to summarise. Run this BEFORE the Keychain wipe
            // and independently of its outcome: the seed has nothing
            // to do with credential cleanup, and gating it on a
            // successful wipe would let a partial wipe failure
            // misroute the user into the "no lastShownWhatsNewVersion"
            // fallback that pops "What's New in vN" on a freshly
            // downloaded version.
            updateNotifyCoordinator.seedWhatsNewOnFreshInstall()
            #endif

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
                AuthTokenManager.accessTokenKey,
                AuthTokenManager.refreshTokenKey,
                AuthTokenManager.expiresAtKey,
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

        #if os(iOS)
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

        #if DEBUG
        // Flipping the debug clock must drive an LA refresh; otherwise the
        // coordinator only re-evaluates on scene-active and the user has
        // to leave/re-enter the app to see the Dynamic Island appear at the
        // fake instant. Reminder reschedule rides along because reminders
        // are also AppClock-keyed (see AssignmentReminderScheduler).
        clockObserver = NotificationCenter.default.addObserver(
            forName: DebugClockController.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLiveActivityRefresh()
        }
        #endif
        #endif

        runPendingMigrations()

        #if os(iOS)
        liveActivityCoordinator.setUpdateTokenRegistrationHandler { [weak self] registration in
            await self?.pushCoordinator.registerLiveActivityUpdateToken(registration)
        }

        // Auto-enable the push stack on every launch so the device row
        // exists in the backend regardless of subscription state — that's
        // what lets operator-issued custom pushes target the device. The
        // coordinator is idempotent. Notification *permission* is still
        // requested through onboarding, not here; users can opt out of
        // server pushes via `serverPushUserOptOut`.
        pushCoordinator.enable()

        // Wire v3 JWT sign-in into the NTUST login flow. AuthService owns the
        // credential path but not the token store; hand it the same
        // AuthTokenManager built above (keyed to the shared device UUID) so a
        // successful SSO login also mints the Bearer that authorizes every
        // /v3 push + bulletin call. Without this the auto-registration above
        // goes out with no Authorization header and 401s on every launch.
        authService.authTokenManager = atm
        authService.onV3SignedIn = { [weak self] in
            guard let self else { return }
            // The launch-time registration ran before any JWT existed and
            // 401'd; now that a Bearer is available, re-register the device
            // and sync the schedule.
            self.pushCoordinator.refreshRegistrationAfterAuth()
            self.requestPushScheduleSync()
        }
        #endif

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
        #if os(iOS)
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
        #if DEBUG
        if let observer = clockObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        #endif
        #endif
    }

    struct SyncConflictItem: Identifiable {
        let id: String
        let kind: String
        let label: String
        let localStatus: String
        let serverStatus: String

        var localLabel: String {
            switch localStatus {
            case "ignored", "archived": return "已忽略"
            case "locally_completed": return "標示為完成"
            default: return "原始狀態"
            }
        }
        var serverLabel: String {
            switch serverStatus {
            case "ignored", "archived": return "已忽略"
            case "locally_completed": return "標示為完成"
            default: return "原始狀態"
            }
        }
    }

    var syncConflicts: [SyncConflictItem] = []
    private var pendingSyncServerArchived: Set<String> = []
    private var pendingSyncServerCompleted: Set<String> = []

    func resolveSyncConflicts(keepLocal: Bool) {
        if keepLocal {
            for c in syncConflicts {
                syncAssignmentOverride(moodleId: c.id, status: c.localStatus)
            }
        } else {
            let safeArchived = pendingSyncServerArchived.union(
                DataCache.shared.loadArchivedAssignmentIds().filter { pendingOverrides.contains($0) }
            )
            let safeCompleted = pendingSyncServerCompleted.union(
                DataCache.shared.loadLocallyCompletedAssignmentIds().filter { pendingOverrides.contains($0) }
            )
            DataCache.shared.replaceArchivedAssignmentIds(safeArchived)
            DataCache.shared.replaceLocallyCompletedAssignmentIds(safeCompleted)
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        }
        syncConflicts = []
        pendingSyncServerArchived = []
        pendingSyncServerCompleted = []
    }

    enum SyncSource { case none, backend, local }
    private(set) var lastSyncSource: SyncSource = .none
    private var pendingOverrides: Set<String> = []


    private var _libraryRevision = 0
    private var syncTask: Task<Void, Never>?
    private var relabelTask: Task<Void, Never>?

    #if os(iOS)
    // MARK: - Live Activity (iOS only — ActivityKit + reminder scheduler
    // are platform-restricted; Mac has no equivalent surfaces).

    let liveActivityPreferences = LiveActivityPreferencesStore()
    private let liveActivityCoordinator = LiveActivityCoordinator()
    private let reminderScheduler = AssignmentReminderScheduler()
    private let scenarioResolver = LiveActivityScenarioResolver()
    private let timelineResolver = CourseTimelineResolver()
    private let courseProvider = CanonicalCourseProvider()
    private var liveActivityObserver: Any?
    private var preferencesObserver: Any?
    private var skipStateObserver: Any?
    #if DEBUG
    private var clockObserver: Any?
    #endif
    private var pendingRefreshTask: Task<Void, Never>?
    private var boundaryRefreshTask: Task<Void, Never>?

    // MARK: - Push server (iOS only — APNs on Mac is a separate decision
    // and the entire PushCoordinator stack pulls in ActivityKit symbols).

    let pushCoordinator: PushCoordinator
    /// Manages v3 JWT tokens for the push backend. Initialised from the
    /// same `PushIdentity` UUID that `PushCoordinator` uses so the two
    /// always agree on the client device ID sent to `/v3/auth/login`.
    let authTokenManager: AuthTokenManager

    // MARK: - Custom-push tap routing

    /// In-process deep-link targets resolved from a custom-push tap. The
    /// `NotificationDelegate` writes here; the destination view observes
    /// and clears the value once it has acted on it.
    enum DeepLink: Equatable {
        case bulletin(Int)
    }

    /// Payload for an operator-issued popup push. `id` is the server-side
    /// notification id and is also used by SwiftUI's `.alert(_:isPresented:
    /// presenting:)` for view identity, so re-tapping the same notification
    /// while the previous alert is still on screen does not double-present.
    struct ServerPopupPayload: Equatable, Identifiable {
        let id: String   // notification_id
        let title: String
        let body: String
    }

    /// Set by the notification delegate when the user taps a
    /// `custom_push_bulletin` push. Bulletins UI observes this and clears
    /// it after navigating into the detail view.
    var pendingDeepLink: DeepLink?

    /// Set by the notification delegate when the user taps a
    /// `custom_push_popup` push and the id has not been shown before.
    /// The root view presents an alert against this binding and clears
    /// the value when the user dismisses.
    var pendingServerPopup: ServerPopupPayload?

    /// In-flight task that re-assigns `pendingServerPopup` after the
    /// nil-bounce used to force SwiftUI's alert to refresh. Stored here
    /// so back-to-back popup taps can cancel a stale swap before it
    /// wakes from its short sleep and overwrites a newer payload.
    /// `@ObservationIgnored` because it isn't UI state.
    @ObservationIgnored
    var pendingServerPopupSwapTask: Task<Void, Never>?

    /// Has the user already been shown the popup for this notification id?
    /// Persisted via `Defaults[.shownServerPopupIds]` as a FIFO list
    /// capped at 100 entries. Read-only — call `markServerPopupShown`
    /// from the alert's dismiss action so an alert that was suppressed
    /// (e.g. by a competing onboarding sheet) isn't permanently deduped.
    @MainActor
    func isServerPopupShown(_ id: String) -> Bool {
        Defaults[.shownServerPopupIds].contains(id)
    }

    /// Record that the user has actually seen the popup for `id`. Only
    /// call this from the alert dismiss path — calling it at routing
    /// time risks marking a popup as seen when its alert never rendered
    /// (mid-onboarding, modal collision, etc.), permanently suppressing
    /// it on future taps.
    @MainActor
    func markServerPopupShown(_ id: String) {
        var seen = Defaults[.shownServerPopupIds]
        if seen.contains(id) { return }
        seen.append(id)
        if seen.count > 100 {
            seen.removeFirst(seen.count - 100)
        }
        Defaults[.shownServerPopupIds] = seen
    }
    #endif

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

    // MARK: - Widget deep linking

    /// Set by `TigerDuckApp.onOpenURL` when a widget tap deep-links into the
    /// app. `MainTabView` observes this and updates its local `selectedTab`,
    /// then calls `clearPendingWidgetDestination()`. Stored here (rather than
    /// on the tab view) so a cold-launch tap still resolves correctly: the
    /// destination is set before MainTabView appears, and MainTabView's
    /// `.onAppear` drain picks it up.
    var pendingWidgetDestination: WidgetDestination?

    /// Transient signal from the library-shortcut widget: when the user taps
    /// the widget while the library feature is disabled, `MainTabView` switches
    /// to the More tab and raises this flag so `MoreView` surfaces an
    /// "enable first" alert. Not persisted — lives only within the process.
    var pendingLibraryEnablePrompt = false

    /// Transient deep-link into the More tab's NavigationStack. Set when a
    /// feature needs to be opened but isn't pinned as a top-level tab (e.g.
    /// flip-to-Library when the user hasn't added the Library tab to their
    /// tab bar). `MoreView` observes this, appends the feature to its local
    /// navigationPath, and clears the flag. Not persisted.
    var pendingMoreDeepLink: AppFeature?

    func openFromWidget(_ destination: WidgetDestination) {
        pendingWidgetDestination = destination
    }

    func clearPendingWidgetDestination() {
        pendingWidgetDestination = nil
    }

    var isLibraryLoggedIn: Bool {
        _ = _libraryRevision
        return LibraryService.isTokenValid
    }

    var libraryUsername: String? {
        _ = _libraryRevision
        return LibraryService.storedUsername
    }

    /// `@MainActor` because `LibraryService.clearCredentials` is now
    /// MainActor-isolated (it sync-broadcasts to the watch). The only
    /// caller is a SwiftUI logout button, which is already on main.
    @MainActor
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
        #if os(iOS)
        pendingRefreshTask?.cancel()
        pendingRefreshTask = nil
        boundaryRefreshTask?.cancel()
        boundaryRefreshTask = nil
        #endif

        authService.logout()
        #if os(iOS)
        // Clear v3 JWT tokens so the next login session starts fresh.
        Task { await authTokenManager.logout() }
        #endif
        // Drop the Mac skip-login bypass too; otherwise a Mac user who
        // skipped, then logged in, then logged out, would stay in
        // `MacContentView` instead of returning to `MacLoginView`.
        didSkipMacLogin = false
        DataCache.shared.clearUserScopedData()
        Task { @MainActor in
            #if os(iOS)
            await liveActivityCoordinator.endAll()
            await reminderScheduler.cancelAllOwnedRequests()
            #endif
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
            #if os(iOS)
            // Accent color only affects the Live Activity snapshot — reminder
            // notifications are content-identical, so skip rescheduling to
            // avoid thrashing UNUserNotificationCenter on slider drags.
            scheduleLiveActivityRefresh(rescheduleReminderNotifications: false)
            #endif
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

    /// Mac-only: where the "open in Moodle" actions route to. The iPad
    /// Moodle app installed via Mac App Store registers `moodlemobile://`
    /// too, so users who installed it can opt into the deep-link path.
    /// iOS ignores this — it always uses the deep link.
    var macMoodleOpenTarget: MoodleOpenTarget = Defaults[.macMoodleOpenTarget] {
        didSet { Defaults[.macMoodleOpenTarget] = macMoodleOpenTarget }
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

    /// Whether the "flip phone face-down to open Library QR" gesture is armed.
    /// iPhone-only at the read site; macOS still persists the bool via
    /// `Defaults` since the property lives on the cross-platform `AppState`.
    var flipToLibraryEnabled: Bool = Defaults[.flipToLibraryEnabled] {
        didSet { Defaults[.flipToLibraryEnabled] = flipToLibraryEnabled }
    }

    /// User-selected multiplier applied to the course-name font in the
    /// class table (`TimetableGridView`) and the course-name labels
    /// inside home-screen widgets. 1.0 = pre-feature baseline.
    ///
    /// Persisted through ``CourseCardFontScaleStore`` (App Group
    /// `UserDefaults`) rather than the `Defaults` library because the
    /// widget extension also reads this key — keeping it in the same
    /// suite avoids a second source-of-truth for the widget side.
    var courseCardFontScale: Double = CourseCardFontScaleStore().read() {
        didSet {
            // Compare on the normalized (snapped) values so the slider's
            // every-frame writes during a drag don't all trigger a
            // widget reload — only when the user crossed a step boundary
            // do we persist + reload. The store always writes the
            // normalized value, so downstream readers (widgets,
            // TimetableGridView) see snapped sizes regardless of the
            // raw in-memory binding state.
            let newSnapped = CourseCardFontScale.normalize(courseCardFontScale)
            let oldSnapped = CourseCardFontScale.normalize(oldValue)
            guard newSnapped != oldSnapped else { return }
            CourseCardFontScaleStore().write(newSnapped)
            // Widgets render in a separate process; ask the coordinator
            // for a debounced reload so a fast slider drag collapses
            // into a single timeline refresh instead of one-per-step.
            // Snapshot data is unchanged, so we skip the
            // WidgetSnapshotWriter regenerate pipeline.
            let coordinator = widgetReloadCoordinator
            Task { @MainActor in
                coordinator.requestReload()
            }
        }
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
        // `Task.detached` lets the loop body yield to the runtime between
        // iterations, so a long relabel sweep doesn't pin the MainActor.
        // The actual disk/SwiftData work hops to MainActor per iteration
        // because `DataCache` and `NameAbbrService.relabelInPlace` touch
        // SwiftData-managed types that are themselves MainActor-isolated.
        relabelTask = Task.detached(priority: .userInitiated) {
            let courseAbbrEnabled = Defaults[.useEnglishCourseAbbreviation]
            let classroomAbbrEnabled = Defaults[.useEnglishClassroomAbbreviation]
            let classroomMandarinDisplay = Defaults[.classroomMandarinDisplay]

            var anyChanged = false
            var code = CourseSelectionService.currentSemesterCode()
            var consecutiveEmpty = 0
            for _ in 0..<AppConstants.cachedSemesterRelabelDepth {
                if Task.isCancelled { return }
                // Snapshot `code` into a `let` so the Sendable closure passed
                // to `MainActor.run` captures an immutable value — Swift 6
                // rejects capturing the mutating outer `var` from a
                // concurrently-executing context.
                let semesterCode = code
                let iter = await MainActor.run { () -> (changed: Bool, wasEmpty: Bool) in
                    let courses = DataCache.shared.loadCourses(semester: semesterCode)
                    if courses.isEmpty { return (false, true) }
                    let changed = NameAbbrService.shared.relabelInPlace(
                        courses,
                        courseAbbrEnabled: courseAbbrEnabled,
                        classroomAbbrEnabled: classroomAbbrEnabled,
                        classroomMandarinDisplay: classroomMandarinDisplay
                    )
                    // Re-check cancellation inside the MainActor body: a
                    // newer toggle can have cancelled this task while it
                    // was queued for the main actor, and persisting now
                    // would clobber the newer task's save with stale
                    // toggle values captured at the top of this closure.
                    if changed && !Task.isCancelled {
                        DataCache.shared.saveCourses(courses, semester: semesterCode)
                    }
                    return (changed, false)
                }
                if iter.wasEmpty {
                    consecutiveEmpty += 1
                    // Two empty semesters in a row means we've walked past any
                    // data the user has fetched; further iterations just hit
                    // disk for nothing.
                    if consecutiveEmpty >= 2 { break }
                } else {
                    consecutiveEmpty = 0
                }
                if iter.changed { anyChanged = true }
                code = CourseSelectionService.previousSemesterCode(code)
            }

            // User-added courses live in their own file, outside the per-semester
            // fetch cache, so the loop above never sees them. Relabel separately
            // so manually-added Mandarin classrooms also honor the display toggle.
            if Task.isCancelled { return }
            let userChanged = await MainActor.run { () -> Bool in
                let userAdded = DataCache.shared.loadUserAddedCourses()
                guard !userAdded.isEmpty else { return false }
                let changed = NameAbbrService.shared.relabelInPlace(
                    userAdded,
                    courseAbbrEnabled: courseAbbrEnabled,
                    classroomAbbrEnabled: classroomAbbrEnabled,
                    classroomMandarinDisplay: classroomMandarinDisplay
                )
                // Same rationale as the per-semester save above: skip the
                // write if a newer relabel has already superseded this one.
                if changed && !Task.isCancelled {
                    DataCache.shared.saveUserAddedCourses(userAdded)
                }
                return changed
            }
            if userChanged { anyChanged = true }

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

    /// Mac-only sidebar pin list. Kept separate from `configuredTabs`
    /// because the Mac sidebar isn't capped at four items: writing Mac
    /// pins into `configuredTabs` would leak a 5+ item list into iOS's
    /// tab bar, which only supports four user tabs plus More.
    #if os(macOS)
    var macConfiguredTabs: [AppFeature] = {
        if let data = Defaults[.macConfiguredTabsData],
           let rawValues = try? JSONDecoder().decode([String].self, from: data) {
            let features = rawValues.compactMap { AppFeature(rawValue: $0) }
            return features.isEmpty ? AppFeature.macDefaultTabs : features
        }
        return AppFeature.macDefaultTabs
    }() {
        didSet {
            do {
                let data = try JSONEncoder().encode(macConfiguredTabs.map(\.rawValue))
                Defaults[.macConfiguredTabsData] = data
            } catch {
                AppLogger.captureError(error, context: ["phase": "macConfiguredTabs.encode"])
            }
        }
    }
    #endif

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Defaults[.hasCompletedOnboarding] = true
        backgroundSync()
    }

    #if os(iOS)
    // MARK: - Live Activity / reminder refresh (iOS only)

    /// Recomputes the scenario and pushes it to the coordinator. Safe to call
    /// frequently — the coordinator only issues ActivityKit calls when the
    /// snapshot actually changes.
    func refreshLiveActivity() async {
        let now = AppClock.now()
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
        // `boundary` is an app-clock instant; `Task.sleep` runs on the
        // real clock, so under a frozen override the app-clock delta
        // would never elapse and the refresh would re-arm itself
        // forever. Translate to the real instant the boundary maps to
        // before computing the sleep, mirroring the activity end task.
        let realBoundary = AppClock.realTime(forApp: boundary)
        let delay = realBoundary.timeIntervalSinceNow + AppConstants.scenarioBoundarySlackSeconds
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
            // Master switch off -> empty set, which makes the scheduler cancel
            // all pending reminders and bail.
            offsets: liveActivityPreferences.isAssignmentReminderEnabled
                ? liveActivityPreferences.assignmentReminderOffsets
                : []
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
        delegate.onSyncTrigger = { [weak self] in
            await self?.syncOverridesFromBackend()
        }
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
    /// — turning on the Settings toggle. Passes `requestPermission: true`
    /// so the user sees an iOS prompt as feedback for their tap.
    func enablePushServer() {
        Defaults[.pushServerEnabled] = true
        pushCoordinator.enable(requestPermission: true)
        requestPushScheduleSync()
    }

    /// Send the current Moodle token to the backend so the server-side
    /// sync job has a fresh credential. Called on every app foreground.
    /// Fire-and-forget — failure is silent (the sync job just uses the
    /// last-known token until the next successful refresh).
    func refreshMoodleCredentials() async {
        guard await authTokenManager.isLoggedIn else { return }
        guard let token = await MoodleTokenService.shared.currentToken(),
              !token.isEmpty else { return }
        let privateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        do {
            _ = try await pushCoordinator.updateCredentials(
                moodleToken: token,
                moodlePrivateToken: privateToken
            )
        } catch {
            // Best-effort — next foreground retries.
        }
    }

    /// Fetch override state (done/ignored) from the backend and apply it
    /// locally. The assignment LIST comes from Moodle-direct (proven
    /// semester filtering); this only syncs the user's swipe marks.
    func syncOverridesFromBackend(retried: Bool = false) async {
        guard await authTokenManager.isLoggedIn else { return }
        do {
            let json = try await pushCoordinator.fetchFullSync()
            let overridesArray = json["assignment_overrides"] as? [[String: Any]] ?? []

            var serverArchivedIds = Set<String>()
            var serverCompletedIds = Set<String>()
            for o in overridesArray {
                guard let status = o["local_status"] as? String else { continue }
                let moodleId: String?
                if let mid = o["moodle_assignment_id"] as? Int {
                    moodleId = String(mid)
                } else if let assignPk = o["user_assignment_id"] as? Int,
                          let assignments = json["assignments"] as? [[String: Any]] {
                    moodleId = assignments.first(where: { ($0["id"] as? Int) == assignPk })
                        .flatMap { $0["moodle_assignment_id"] as? Int }.map(String.init)
                } else {
                    moodleId = nil
                }
                guard let moodleId else { continue }
                switch status {
                case "archived", "ignored": serverArchivedIds.insert(moodleId)
                case "locally_completed": serverCompletedIds.insert(moodleId)
                default: break
                }
            }

            // First-time migration: upload local overrides if server has none.
            // Only skip the conflict-detection block — course overrides,
            // hard-delete detection, and the dataDidUpdate notification must
            // still run so the first sync after migration picks up colour /
            // custom-name changes and cross-device deletions.
            let localArchivedIds = DataCache.shared.loadArchivedAssignmentIds()
            let localCompletedIds = DataCache.shared.loadLocallyCompletedAssignmentIds()
            let isMigrating = serverArchivedIds.isEmpty && serverCompletedIds.isEmpty
                && (!localArchivedIds.isEmpty || !localCompletedIds.isEmpty)
            if isMigrating {
                for id in localArchivedIds { syncAssignmentOverride(moodleId: id, status: "archived") }
                for id in localCompletedIds { syncAssignmentOverride(moodleId: id, status: "locally_completed") }
            }

            if !isMigrating {
                var conflicts: [(id: String, kind: String, label: String, local: String, server: String)] = []
                let allIds = serverArchivedIds.union(serverCompletedIds).union(localArchivedIds).union(localCompletedIds)
                let assignmentCache = DataCache.shared.loadAssignments()
                let assignmentsByMoodleId = Dictionary(assignmentCache.map { ($0.assignmentId, $0) }, uniquingKeysWith: { first, _ in first })
                for id in allIds where !pendingOverrides.contains(id) {
                    let serverStatus: String
                    if serverArchivedIds.contains(id) { serverStatus = "ignored" }
                    else if serverCompletedIds.contains(id) { serverStatus = "locally_completed" }
                    else { serverStatus = "none" }
                    let localStatus: String
                    if localArchivedIds.contains(id) { localStatus = "ignored" }
                    else if localCompletedIds.contains(id) { localStatus = "locally_completed" }
                    else { localStatus = "none" }
                    if serverStatus != localStatus {
                        let title = assignmentsByMoodleId[id]?.displayTitle ?? "ID \(id)"
                        conflicts.append((id: id, kind: "作業", label: title, local: localStatus, server: serverStatus))
                    }
                }

                // Always apply non-conflicting items
                let conflictIds = Set(conflicts.map(\.id))
                var safeArchived = serverArchivedIds.filter { !conflictIds.contains($0) }
                    .union(DataCache.shared.loadArchivedAssignmentIds().filter { pendingOverrides.contains($0) })
                var safeCompleted = serverCompletedIds.filter { !conflictIds.contains($0) }
                    .union(DataCache.shared.loadLocallyCompletedAssignmentIds().filter { pendingOverrides.contains($0) })
                // Preserve local state for conflicting items until user resolves
                for c in conflicts {
                    switch c.local {
                    case "ignored", "archived": safeArchived.insert(c.id)
                    case "locally_completed": safeCompleted.insert(c.id)
                    default: break
                    }
                }
                DataCache.shared.replaceArchivedAssignmentIds(safeArchived)
                DataCache.shared.replaceLocallyCompletedAssignmentIds(safeCompleted)

                AppLogger.sync.info("applied: \(safeArchived.count, privacy: .public) archived, \(safeCompleted.count, privacy: .public) completed, \(conflicts.count, privacy: .public) conflicts pending")

                if !conflicts.isEmpty {
                    await MainActor.run {
                        syncConflicts = conflicts.map { SyncConflictItem(id: $0.id, kind: $0.kind, label: $0.label, localStatus: $0.local, serverStatus: $0.server) }
                        pendingSyncServerArchived = serverArchivedIds
                        pendingSyncServerCompleted = serverCompletedIds
                    }
                }
            }

            // Course overrides + hard-delete detection always run, even
            // during first-time migration.
            let coursesArray = json["courses"] as? [[String: Any]] ?? []
            let courseOverrides = json["course_overrides"] as? [[String: Any]] ?? []
            if !courseOverrides.isEmpty {
                applyCourseOverrides(courseOverrides, coursesArray: coursesArray)
            }

            // Hard-delete detection: compare server courses against local deletedCourseNos
            if !coursesArray.isEmpty {
                let serverCourseNos = Set(coursesArray.compactMap { $0["course_no"] as? String })
                var deletedNos = Set(DataCache.shared.loadDeletedCourseNos())
                let semester = CourseSelectionService.currentSemesterCode()
                let localCourses = DataCache.shared.loadCourses(semester: semester)
                let localCourseNos = Set(localCourses.map(\.courseNo))
                var changed = false

                // A local course NOT in server courses → deleted on another device
                for courseNo in localCourseNos where !serverCourseNos.contains(courseNo) && !deletedNos.contains(courseNo) {
                    deletedNos.insert(courseNo)
                    changed = true
                    AppLogger.sync.info("course deleted on another device (not in server courses)")
                }

                // A courseNo in deletedNos that IS in server courses → un-deleted
                for courseNo in deletedNos where serverCourseNos.contains(courseNo) {
                    deletedNos.remove(courseNo)
                    changed = true
                    AppLogger.sync.info("course un-deleted (present in server courses)")
                }

                if changed {
                    DataCache.shared.saveDeletedCourseNos(Array(deletedNos))
                    let filtered = localCourses.filter { !deletedNos.contains($0.courseNo) }
                    if filtered.count != localCourses.count {
                        DataCache.shared.saveCourses(filtered, semester: semester)
                    }
                }
            }

            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
            lastSyncSource = .backend
        } catch {
            lastSyncSource = .local
            if case PushAPIError.httpStatus(401, _) = error, !retried {
                let reloginOk = await attemptBackendRelogin()
                if reloginOk {
                    AppLogger.sync.info("auto-relogin succeeded, retrying sync")
                    try? await Task.sleep(for: .milliseconds(500))
                    await syncOverridesFromBackend(retried: true)
                }
            }
            AppLogger.sync.error("syncOverrides failed: \(error, privacy: .public)")
        }
    }

    private func applyCourseOverrides(_ overrides: [[String: Any]], coursesArray: [[String: Any]]) {
        // Build moodleId → courseNo from courses array
        var moodleIdToNo: [String: String] = [:]
        for c in coursesArray {
            guard let mId = c["moodle_id"] as? String ?? (c["moodle_id"] as? Int).map(String.init) else { continue }
            if let courseNo = c["course_no"] as? String, !courseNo.isEmpty {
                moodleIdToNo[mId] = courseNo
            } else if let name = c["course_name"] as? String, let bracketEnd = name.firstIndex(of: "】") {
                let rest = name[name.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
                let code = rest.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
                if !code.isEmpty { moodleIdToNo[mId] = code }
            }
        }
        AppLogger.sync.info("moodleIdToNo: \(moodleIdToNo.count, privacy: .public) entries, overrides: \(overrides.count, privacy: .public)")

        var customNames = DataCache.shared.loadCourseCustomNames()
        var colorCount = 0
        var nameCount = 0
        for o in overrides {
            guard let mId = o["moodle_id"] as? String ?? (o["moodle_id"] as? Int).map(String.init) else { continue }
            guard let courseNo = moodleIdToNo[mId] else { continue }
            if let colorHex = o["color_hex"] as? String, !colorHex.isEmpty {
                if let hex = UInt32(colorHex.dropFirst(), radix: 16) {
                    TigerDuckTheme.setColor(hex: hex, for: courseNo)
                    colorCount += 1
                    AppLogger.sync.debug("course color applied")
                }
            }
            if let serverNames = o["custom_names"] as? [String: String], !serverNames.isEmpty {
                var existing = customNames[courseNo] ?? [:]
                for (locale, name) in serverNames {
                    if name.isEmpty {
                        existing.removeValue(forKey: locale)
                    } else {
                        existing[locale] = name
                    }
                }
                customNames[courseNo] = existing.isEmpty ? nil : existing
                nameCount += 1
                AppLogger.sync.debug("course custom names updated")
            }
        }
        if nameCount > 0 {
            DataCache.shared.saveCourseCustomNames(customNames)
        }
    }

    private func attemptBackendRelogin() async -> Bool {
        #if os(iOS)
        let atm = authTokenManager
        guard let studentId = authService.storedStudentId else { return false }
        let moodleToken = await MoodleTokenService.shared.currentToken()
        let moodlePrivateToken = KeychainManager.loadString(
            key: AppConstants.KeychainKeys.moodlePrivateToken
        )
        guard let moodleToken, !moodleToken.isEmpty else {
            AppLogger.sync.info("auto-relogin skipped: no Moodle token")
            return false
        }
        let platform = PushDeviceClass.platform(for: PushDeviceClass.resolvedForBuild)
        let deviceName = UIDevice.current.name
        do {
            _ = try await atm.login(
                studentId: studentId,
                password: "",
                moodleToken: moodleToken,
                moodlePrivateToken: moodlePrivateToken,
                platform: platform,
                deviceName: deviceName
            )
            AppLogger.sync.info("auto-relogin: v3 JWT refreshed")
            return true
        } catch {
            AppLogger.sync.error("auto-relogin failed: \(error, privacy: .public)")
            return false
        }
        #else
        return false
        #endif
    }

    /// Fire-and-forget override sync to the backend. Local state is already
    /// updated by the ViewModel; this propagates to other devices.
    func syncAssignmentOverride(moodleId: String, status: String) {
        AppLogger.sync.debug("override sending: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        pendingOverrides.insert(moodleId)
        Task {
            do {
                _ = try await pushCoordinator.patchAssignmentOverride(
                    moodleAssignmentId: moodleId, localStatus: status
                )
                pendingOverrides.remove(moodleId)
                AppLogger.sync.debug("override patch ok: \(moodleId, privacy: .private) → \(status, privacy: .public)")
            } catch {
                AppLogger.sync.error("override patch failed: \(moodleId, privacy: .private) → \(status, privacy: .public), error=\(error, privacy: .public)")
            }
        }
    }

    func syncCourseOverride(
        moodleCourseId: String,
        isHidden: Bool? = nil,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil
    ) {
        Task {
            _ = try? await pushCoordinator.patchCourseOverride(
                moodleCourseId: moodleCourseId,
                isHidden: isHidden,
                colorHex: colorHex,
                customName: customName,
                locale: locale
            )
        }
    }

    func uploadCourses(_ courses: [SDCourse], semester: String) {
        let entries = courses.map { c in
            PushAPI.CourseUploadEntry(
                semester: semester,
                courseNo: c.courseNo,
                courseName: c.courseName,
                courseNameEn: nil,
                moodleId: c.moodleIdNumber,
                credits: c.credits > 0 ? Double(c.credits) : nil,
                classroom: c.classroom.isEmpty ? nil : c.classroom,
                instructors: c.instructor.isEmpty ? [] : [c.instructor]
            )
        }
        let coordinator = pushCoordinator
        Task.detached {
            try? await coordinator.uploadCourses(
                PushAPI.CourseUploadRequest(courses: entries)
            )
        }
    }

    /// Disable server push (tells server to drop the device, stops relay).
    func disablePushServer() async {
        Defaults[.pushServerEnabled] = false
        await pushCoordinator.disable()
    }

    /// Wire the settings toggle to the registration actor. The actor
    /// PATCHes the backend and only then persists the local pref so a
    /// transient failure doesn't leave the UI claiming agreement with
    /// the server. Throws on failure so the caller can roll back.
    func updateServerPushOptOut(_ optOut: Bool) async throws {
        try await pushCoordinator.registration.updateServerPushOptOut(optOut)
    }
    #endif // os(iOS) — closes the Live Activity / reminder / push block

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
            // Captive-aware reachability — under a hotel / campus Wi-Fi
            // login page the link is "satisfied" but actual egress is
            // blocked, and the pinned NTUST hosts would hard-fail with
            // an ATS error. Bail early with a clean "no internet"
            // message instead.
            guard await NetworkMonitor.shared.isReachable() else {
                await MainActor.run {
                    sessionManager.loadingState = .error(String(localized: "error_network_unavailable"))
                }
                return
            }

            sessionManager.loadingState = .loading

            // Moodle-direct for the assignment list (proven, correct
            // semester filtering). Backend handles override sync only.
            let fetchedAssignments = await AppServiceBridge.fetchAssignments(authService: authService)
            await syncOverridesFromBackend()

            async let schoolEventsTask = CalendarService.fetchAndParseICS()
            async let coursesTask: Bool = syncCoursesIfAuthenticated()

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
