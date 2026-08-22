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
        // Keychain persists across uninstall/reinstall on iOS. Detect a fresh
        // install (no UserDefaults marker) and purge stale Keychain credentials
        // BEFORE constructing AuthTokenManager — its init eagerly caches the v3
        // tokens into memory, so wiping the Keychain afterwards would leave the
        // live manager holding a previous user's tokens and rewrite them on the
        // next refresh, defeating the purge (a different user reinstalling could
        // then sync the previous user's cloud data).
        let isFreshInstall = !Defaults[.appHasBeenInstalled]
        if isFreshInstall {
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
        self.cloudSyncCoordinator = CloudSyncCoordinator(pushCoordinator: self.pushCoordinator)
        CloudSyncCoordinator.registerShared(self.cloudSyncCoordinator)

        #if os(iOS)
        if isFreshInstall {
            // Stamp the running version as "already shown" so the What's New
            // sheet does NOT fire on the very first launch after install — a
            // freshly downloaded app has no upgrade history to summarise.
            // Gated on fresh-install only (never on the wipe outcome above) so
            // a partial wipe failure can't misroute the user into the "no
            // lastShownWhatsNewVersion" fallback that pops "What's New in vN".
            updateNotifyCoordinator.seedWhatsNewOnFreshInstall()
        }
        #endif

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
        #endif

        // Install the refresh-failure relogin handler BEFORE enabling the push
        // stack, so a token refresh triggered by the first registration has a
        // relogin path instead of falling through to logout() on a nil handler.
        Task {
            await atm.setRefreshFailedHandler { [weak self] in
                await self?.attemptBackendRelogin() ?? false
            }
        }

        // Auto-enable the push stack on every launch so the device row
        // exists in the backend regardless of subscription state — that's
        // what lets operator-issued custom pushes target the device. The
        // coordinator is idempotent. Notification *permission* is still
        // requested through onboarding, not here; users can opt out of
        // server pushes via `serverPushUserOptOut`.
        //
        // Gated on onboarding for the same reason `backgroundSync()` is:
        // enabling POSTs a device id and an Apple push token to our server,
        // and on a fresh install `init` runs before the user has seen a
        // single screen. `completeOnboarding()` enables it once they have.
        if hasCompletedOnboarding {
            pushCoordinator.enable()
        }

        authService.authTokenManager = atm
        authService.onV3SignedIn = { [weak self] in
            guard let self else { return }
            self.pushCoordinator.refreshRegistrationAfterAuth()
            self.requestPushScheduleSync()
        }

        // Apply a stored in-app language override on launch so string lookups
        // use the user's chosen locale. Skip when "system" — calling apply()
        // there would removeObject(AppleLanguages), wiping the per-app override
        // iOS Settings writes to that same key.
        if appLanguage != LanguageManager.system {
            LanguageManager.apply(appLanguage)
        }
    }

    deinit {
        revisionPollTimer?.invalidate()
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

    var syncConflicts: [SyncConflictItem] = []

    var pendingSyncServerArchived: Set<String> = []
    var pendingSyncServerCompleted: Set<String> = []

    /// Stored here rather than in AppState+Conflicts.swift only because Swift
    /// extensions cannot hold stored properties. The type and every decision
    /// that reads it live in that file.
    var reenableConflict: ReenableConflict?

    /// Which side won the last override pull. `private(set)` on purpose —
    /// roughly a hundred view files read this to decide whether to show the
    /// "local only" badge, and none of them should be able to assign it.
    /// AppState+BackendSync sets it through ``recordSyncSource(_:)``.
    private(set) var lastSyncSource: SyncSource = .none

    func recordSyncSource(_ source: SyncSource) {
        lastSyncSource = source
    }
    var pendingOverrides: Set<String> = []
    /// Bumped on every local assignment-override edit. A pull whose fetch
    /// window contains a bump skips conflict detection for that round —
    /// its server payload is stale relative to the edit.
    var overrideEditGeneration = 0

    /// Reentrancy guard for `syncOverridesFromBackend`. The revision poll,
    /// pull-to-refresh, and sync_trigger push can all invoke it concurrently;
    /// they run on the MainActor but interleave at await suspension points, so
    /// without this they clobber each other's cache read-modify-writes and can
    /// resurrect a just-dismissed conflict alert.
    var isSyncingOverrides = false

    /// In-flight guard for ``checkPendingConflicts``. See the comment there.
    var isCheckingConflicts = false

    /// courseNo → local delete timestamp. The sync reconcile skips
    /// "un-deleting" a course still listed by the server if the user deleted it
    /// within the grace window — its backend DELETE may not have propagated
    /// yet, and un-deleting would flap the course back into the timetable.
    var recentCourseDeletions: [String: Date] = [:]
    static let courseDeleteGraceInterval: TimeInterval = 120

    var _libraryRevision = 0
    var syncTask: Task<Void, Never>?
    var relabelTask: Task<Void, Never>?

    // MARK: - Revision polling

    /// Last known server revision. When the server reports a higher value
    /// the poller triggers a full sync via ``syncOverridesFromBackend()``.
    @ObservationIgnored
    var _lastKnownRevision: Int = 0

    /// Repeating timer that fires every 10 s while the app is foregrounded.
    @ObservationIgnored
    var revisionPollTimer: Timer?

    #if os(iOS)
    // MARK: - Live Activity (iOS only — ActivityKit + reminder scheduler
    // are platform-restricted; Mac has no equivalent surfaces).

    let liveActivityPreferences = LiveActivityPreferencesStore()
    let liveActivityCoordinator = LiveActivityCoordinator()
    let reminderScheduler = AssignmentReminderScheduler()
    let scenarioResolver = LiveActivityScenarioResolver()
    let timelineResolver = CourseTimelineResolver()
    let courseProvider = CanonicalCourseProvider()
    private var liveActivityObserver: Any?
    private var preferencesObserver: Any?
    private var skipStateObserver: Any?
    #if DEBUG
    private var clockObserver: Any?
    #endif
    var pendingRefreshTask: Task<Void, Never>?
    var boundaryRefreshTask: Task<Void, Never>?
    #endif // os(iOS) — Live Activity properties

    // MARK: - Push server

    let pushCoordinator: PushCoordinator
    let authTokenManager: AuthTokenManager
    let cloudSyncCoordinator: CloudSyncCoordinator

    #if os(iOS)
    // MARK: - Custom-push tap routing

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
    #endif

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

    /// Cross-device sync toggle. When OFF, all backend sync calls
    /// (override download/upload, course upload, assignment upload) are
    /// skipped and push notifications + Live Activity are unavailable.
    var cloudSyncEnabled: Bool = Defaults[.cloudSyncEnabled] {
        didSet {
            guard cloudSyncEnabled != oldValue else { return }
            Defaults[.cloudSyncEnabled] = cloudSyncEnabled
            if cloudSyncEnabled {
                Task {
                    await cloudSyncCoordinator.enable()
                }
                requestPushScheduleSync()
                startRevisionPolling()
            } else {
                stopRevisionPolling()
                Task { await cloudSyncCoordinator.disable() }
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

}
