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

    /// Coordinator owning the iTunes Lookup + What's New plumbing. Lives
    /// on `AppState` (not as a top-level singleton) so SwiftUI views observe
    /// changes through the same `@Environment(AppState.self)` they already
    /// use, and so its sheet-presentation flags reset alongside the rest of
    /// app state on logout / fresh install paths. The Mac uses only its
    /// update check.
    let updateNotifyCoordinator = UpdateNotifyCoordinator()

    // MARK: - Fresh Install Keychain Cleanup

    /// Keychain persists across app uninstall/reinstall on iOS.
    /// Detect fresh install (no UserDefaults marker) and clear stale Keychain data
    /// so the app doesn't start with orphaned credentials from a previous install.
    init() {
        // On iOS, Keychain items survive a reinstall. Purge them before constructing
        // AuthTokenManager: its init caches the v3 tokens, which it would rewrite on the
        // next refresh, letting a different user sync the previous user's cloud data.
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
        let atm = AuthTokenManager(deviceUUID: identity.uuid)
        self.authTokenManager = atm
        self.pushCoordinator = PushCoordinator(
            identity: identity,
            authTokenManager: atm
        )
        self.cloudSyncCoordinator = CloudSyncCoordinator(pushCoordinator: self.pushCoordinator)
        CloudSyncCoordinator.registerShared(self.cloudSyncCoordinator)

        #if os(iOS)
        if isFreshInstall {
            // Mark this version's What's New as shown: a fresh install has no upgrade
            // history. Gated on fresh install, not the wipe outcome, so a partial wipe
            // failure can't hit the missing-`lastShownWhatsNewVersion` fallback.
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
        ) { [weak self] note in
            self?.scheduleLiveActivityRefresh()
            self?.requestPushScheduleSync()
            // Unlike the refreshes above, skip the settings push for a remote-origin post
            // (it would write the `notification` document back to itself) and for a
            // device-only post (nothing the document carries changed).
            guard NotificationSettingsSync.changeNeedsDocumentPush(note.userInfo) else { return }
            self?.scheduleNotificationSettingsPush()
        }

        skipStateObserver = NotificationCenter.default.addObserver(
            forName: AppConstants.courseSkipStateDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleLiveActivityRefresh()
        }

        #if DEBUG
        // Flipping the debug clock must refresh the Live Activity. Otherwise the
        // coordinator only re-evaluates on scene-active, and the Dynamic Island shows
        // the fake instant only after leaving and re-entering the app.
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
        liveActivityCoordinator.setAvailabilityProvider { [weak self] in
            self?.isLiveActivityAvailable ?? false
        }
        liveActivityCoordinator.setQuietDayProvider { day in
            AcademicCalendarStore.shared.suppressesClasses(on: day)
        }
        #endif

        // Install before enabling push, so a refresh the first registration triggers can
        // relogin instead of calling logout() on a nil handler. ATM keeps the handler, so
        // capturing self strongly is a cycle; a strong Task capture defeats the inner weak one.
        Task { [weak self] in
            await atm.setRefreshFailedHandler { [weak self] in
                await self?.attemptBackendRelogin() ?? false
            }
        }

        // Enable every launch so the device row exists whatever the subscription state and
        // operator pushes reach it. Idempotent; permission comes from onboarding and opt-out
        // from `serverPushUserOptOut`. It POSTs device ids, so it waits for onboarding.
        if hasCompletedOnboarding {
            pushCoordinator.enable()
        }

        authService.authTokenManager = atm
        authService.onV3SignedIn = { [weak self] in
            guard let self else { return }
            self.pushCoordinator.refreshRegistrationAfterAuth()
            self.requestPushScheduleSync()
            #if os(iOS)
            // Read the account's notification settings before anything writes them.
            // A push here would overwrite the account's document with this device's
            // values, including ones a previous account left behind.
            self.reconcileNotificationSettings()
            #endif
        }

        // Every change to Sync course information, whichever writer
        // made it — see `cloudSyncEnabled`.
        cloudSyncPreference.onChange { [weak self] enabled in
            self?.cloudSyncEnabledDidChange(to: enabled)
        }

        // Apply a stored in-app language override at launch so lookups use it. Skip
        // "system": apply() would remove AppleLanguages, wiping the per-app override
        // that iOS Settings writes to the same key.
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

    /// Terms whose reset DELETE is in flight or whose local wipe is still
    /// running. A snapshot reconciled inside that window sees the server
    /// either still full or just emptied and the caches either still full
    /// or just emptied, and every combination but the right one puts the
    /// old roster somewhere it gets uploaded from; the reconcile skips the
    /// term. In memory: it only has to outlive one round trip. What is
    /// fetched before the DELETE but reconciled after the latch is gone is
    /// `DataCache.loadSemesterResetAt`'s job.
    var resettingSemesters: Set<String> = []

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
    // MARK: - Live Activity (iOS only — ActivityKit is platform-restricted;
    // Mac has no equivalent surface).

    let liveActivityPreferences = LiveActivityPreferencesStore()
    let liveActivityCoordinator = LiveActivityCoordinator()
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
            // Accent color only affects the Live Activity snapshot.
            scheduleLiveActivityRefresh()
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

    /// Cross-device sync toggle (Sync course information). When off, every
    /// backend sync call (override download and upload, course and assignment
    /// upload) is skipped; push notifications and Live Activities are unavailable.
    ///
    /// Reads and writes `Defaults[.cloudSyncEnabled]` through
    /// `cloudSyncPreference`, not a copy, so it cannot disagree with onboarding,
    /// the settings switches or sign-out. `cloudSyncEnabledDidChange(to:)` runs
    /// for every change, whichever writer made it.
    var cloudSyncEnabled: Bool {
        get { cloudSyncPreference.isEnabled }
        set { cloudSyncPreference.isEnabled = newValue }
    }

    let cloudSyncPreference = CloudSyncPreference()

    /// Everything a change to Sync course information sets off.
    /// `cloudSyncPreference` calls it once per change, whichever writer made it.
    ///
    /// Nothing in here writes the preference, and `CloudSyncCoordinator` only
    /// follows it, so no side effect can come back around as another change.
    private func cloudSyncEnabledDidChange(to enabled: Bool) {
        // The status dot's backend row means a full sync result with sync on and a
        // public GET's reachability with it off. Drop the old reading so no unearned
        // green "Minimal" lingers. The next fetch refills it; when off, the calendar refresh.
        ServerStatusTracker.shared.clearBackendStatus()
        cloudSyncCoordinator.followPreference()
        // On: push the schedule Live Activities start from. Off: push an empty one,
        // which cancels every start the server queued for this device.
        requestPushScheduleSync()
        if enabled {
            startRevisionPolling()
            #if os(iOS)
            // Resumes without a relaunch. `isLiveActivityEnabled` itself
            // was never touched while sync was off, so this restores
            // exactly what the user had.
            scheduleLiveActivityRefresh()
            #endif
        } else {
            stopRevisionPolling()
            #if os(iOS)
            // A privacy-style shutoff, like logout: end what is on screen now, not at
            // the next refresh. `LiveActivityCoordinator` applies the same rule and ends
            // anything the server still starts afterwards on arrival.
            Task { @MainActor in await liveActivityCoordinator.endAll() }
            #endif
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

    /// Assignment time display: true = absolute (2026/3/24 23:59:00), false = relative (in 5 days)
    var showAbsoluteAssignmentTime: Bool = Defaults[.showAbsoluteAssignmentTime] {
        didSet { Defaults[.showAbsoluteAssignmentTime] = showAbsoluteAssignmentTime }
    }

    /// Keep every period on the timetable even when empty.
    var alwaysShowAllPeriods: Bool = Defaults[.alwaysShowAllPeriods] {
        didSet { Defaults[.alwaysShowAllPeriods] = alwaysShowAllPeriods }
    }

    /// Show each course's room under its name in the class table.
    var showClassroomInClassTable: Bool = Defaults[.showClassroomInClassTable] {
        didSet { Defaults[.showClassroomInClassTable] = showClassroomInClassTable }
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
            // Compare snapped values so a drag's per-frame writes persist and reload
            // widgets only on crossing a step boundary. The store writes the snapped
            // value, so widgets and TimetableGridView never see the raw binding state.
            let newSnapped = CourseCardFontScale.normalize(courseCardFontScale)
            let oldSnapped = CourseCardFontScale.normalize(oldValue)
            guard newSnapped != oldSnapped else { return }
            CourseCardFontScaleStore().write(newSnapped)
            // Widgets render in another process, so request a debounced reload: a fast
            // drag collapses into one timeline refresh. Snapshot data is unchanged, so
            // the WidgetSnapshotWriter regenerate pipeline is skipped.
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
            // AppServiceBridge.fetchCourses snapshots the language at task start, so a
            // sync still in flight from the previous locale could land after the refresh
            // and overwrite DataCache with old-locale names. Cancel it.
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

    /// Pure decode step for `configuredTabs`: `Data → [String] → [AppFeature]`, filtered by
    /// `isShown` (default `isImplemented`). `compactMap` drops raw values this build does not
    /// recognise in saved or synced config, and the filter drops features this build hides
    /// (`.schoolMail` on macOS, where `SchoolMailAvailability.isEnabled` is false). What
    /// `TabEditorView` offers (`pinnableFeatures`) is filtered the same way, so this only
    /// catches stale data. Returns `nil` for missing or undecodable `data`, or when nothing
    /// survives, so callers can substitute their own default tabs. Free of `Defaults`, so it
    /// is testable without touching UserDefaults.
    nonisolated static func decodeConfiguredTabs(
        _ data: Data?,
        isShown: (AppFeature) -> Bool = { $0.isImplemented }
    ) -> [AppFeature]? {
        guard let data, let rawValues = try? JSONDecoder().decode([String].self, from: data) else {
            return nil
        }
        let features = rawValues.compactMap { AppFeature(rawValue: $0) }.filter(isShown)
        return features.isEmpty ? nil : features
    }

    var configuredTabs: [AppFeature] = {
        AppState.decodeConfiguredTabs(Defaults[.configuredTabsData]) ?? AppFeature.defaultTabs
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
