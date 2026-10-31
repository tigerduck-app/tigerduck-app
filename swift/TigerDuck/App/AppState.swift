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

    var isShowingNTUSTLoginSheet = false

    var didSkipMacLogin = false

    let authService: AuthService
    let sessionManager = NTUSTSessionManager.shared

    let updateNotifyCoordinator = UpdateNotifyCoordinator()

    /// Keychain persists across app uninstall/reinstall on iOS.
    /// Detect fresh install (no UserDefaults marker) and clear stale Keychain data
    /// so the app doesn't start with orphaned credentials from a previous install.
    init() {
        // On iOS, Keychain items survive a reinstall. Purge them before constructing
        // AuthTokenManager: its init caches the v3 tokens, which it would rewrite on the
        // next refresh, letting a different user sync the previous user's cloud data.
        let isFreshInstall = !Defaults[.appHasBeenInstalled]
        if isFreshInstall {
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
                AuthTokenManager.refreshTokenUsesKey,
                AuthTokenManager.departingSessionKey,
            ]
            let allOk = keysToWipe
                .map { KeychainManager.deleteReportingSuccess(key: $0) }
                .allSatisfy { $0 }
            if allOk {
                Defaults[.appHasBeenInstalled] = true
            }
        }
        // After the purge, which deletes a reinstall's bare items, and before AuthService reads them.
        // A purge left for the next launch keeps them from moving.
        if Defaults[.appHasBeenInstalled] { BareKeychainItemMoveMigration.runIfNeeded() }

        let authService = AuthService()
        self.authService = authService

        let identity = PushIdentity.loadOrCreate()
        let atm = AuthTokenManager(deviceUUID: identity.uuid)
        self.authTokenManager = atm
        self.pushCoordinator = PushCoordinator(
            identity: identity,
            authTokenManager: atm
        )
        self.cloudSyncCoordinator = CloudSyncCoordinator(
            pushCoordinator: self.pushCoordinator,
            addedCourseUpload: { AppState.addedCourseUpload(semester: $0, courseNo: $1) },
            uploadsCourses: { CourseUploadPolicy.uploadsCourses },
            loginGeneration: { authService.loginGeneration }
        )
        CloudSyncCoordinator.registerShared(self.cloudSyncCoordinator)

        librarySignInObserver = NotificationCenter.default.addObserver(
            forName: LibraryService.signInDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.notifyLibraryStateChanged()
        }

        #if os(iOS)
        if isFreshInstall {
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
            !AcademicCalendarStore.shared.isClassDay(day)
        }
        liveActivityCoordinator.setAssignmentOutstandingProvider { id in
            LiveActivityScenarioResolver.isOutstanding(
                assignmentId: id,
                in: DataCache.shared.loadAssignments()
            )
        }
        liveActivityCoordinator.setSkippedClassProvider { slotId in
            let courses = CanonicalCourseProvider().currentCourses()
            return CourseTimeSlot.isSkipped(slotId: slotId, in: courses)
                || CourseTimeSlot.hasEnded(slotId: slotId, in: courses, at: AppClock.now())
        }
        #endif

        Task { [weak self] in
            await atm.setRefreshFailedHandler { [weak self, weak atm] in
                await self?.attemptBackendRelogin(replacing: await atm?.storedAccessToken) ?? false
            }
            await atm.setNoSessionHandler { [weak self] in
                await self?.authService.ensureBackendSignedIn()
            }
        }

        if hasCompletedOnboarding {
            pushCoordinator.enable()
        }
        if Self.retriesDepartingUnregister(
            onboarded: hasCompletedOnboarding, signedIn: authService.hasStoredCredentials,
            keptOn: atm.departingSessionBackends, backend: PushServerConfig.resolveServerURL()
        ) {
            authService.startDepartingUnregisterRetry { [pushCoordinator] in
                await atm.retryDepartingUnregister { await pushCoordinator.registration.unregisterDevice(at: $0) }
            }
        }

        authService.authTokenManager = atm
        authService.onV3SignedIn = { [weak self] in
            guard let self else { return }
            self.pushCoordinator.refreshRegistrationAfterAuth()
            self.requestPushScheduleSync()
            #if os(iOS)
            self.reconcileNotificationSettings()
            #endif
        }
        authService.signOutStoredAccount = { [weak self] in
            await self?.logoutNTUST().value
        }
        authService.forgetPages = { await AuthService.forgetSchoolPages() }

        cloudSyncPreference.onChange { [weak self] enabled in
            self?.cloudSyncEnabledDidChange(to: enabled)
        }
        cloudSyncCoordinator.adoptKeptValue = { [weak self] in self?.adoptKeptValue($0) }

        AppServiceBridge.courseUploader = { [weak self] courses, semester, asRoster, resend in
            self?.uploadCourses(courses, semester: semester, asRoster: asRoster, resend: resend)
        }
        AppServiceBridge.assignmentUploader = { [weak self] request in
            self?.uploadAssignments(request)
        }
        revisionPoller.poll = { [weak self] in await self?.pollRevision() ?? .unchanged }
        revisionPoller.relogin = { [weak self] in await self?.attemptBackendRelogin(replacing: $0) ?? false }

        // Apply a stored in-app language override at launch so lookups use it. Skip
        // "system": apply() would remove AppleLanguages, wiping the per-app override
        // that iOS Settings writes to the same key.
        if appLanguage != LanguageManager.system {
            LanguageManager.apply(appLanguage)
        }
    }

    deinit {
        if let observer = librarySignInObserver {
            NotificationCenter.default.removeObserver(observer)
        }
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

    var reenableConflict: ReenableConflict?

    private(set) var lastSyncSource: SyncSource = .none

    func recordSyncSource(_ source: SyncSource) {
        lastSyncSource = source
    }
    var pendingOverrides: Set<String> = []
    var overrideEditGeneration = 0

    @ObservationIgnored
    let fullSyncGate = FullSyncGate()

    var isCheckingConflicts = false

    var conflictCheckRetry = ConflictCheckRetry()

    var recentCourseDeletions: [String: Date] = [:]
    static let courseDeleteGraceInterval: TimeInterval = 120

    var resettingSemesters: Set<String> = []

    var useLocalHold = UseLocalHold()

    var _libraryRevision = 0
    private var librarySignInObserver: Any?
    var syncTask: Task<Void, Never>?
    var relabelTask: Task<Void, Never>?

    @ObservationIgnored
    var _lastKnownRevision: Int = 0

    @ObservationIgnored
    let revisionPoller = RevisionPoller()

    #if os(iOS)

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
    #endif

    let pushCoordinator: PushCoordinator
    let authTokenManager: AuthTokenManager
    let cloudSyncCoordinator: CloudSyncCoordinator

    #if os(iOS)

    var pendingDeepLink: DeepLink?

    var pendingServerPopup: ServerPopupPayload?

    @ObservationIgnored
    var pendingServerPopupSwapTask: Task<Void, Never>?
    #endif

    var pendingWidgetDestination: WidgetDestination?

    var pendingMoreDeepLink: AppFeature?

    var accentColorHex: Int = Defaults[.accentColorHex] {
        didSet {
            Defaults[.accentColorHex] = accentColorHex
            NotificationCenter.default.post(name: AppConstants.accentColorDidChange, object: nil)
            #if os(iOS)
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
    ]

    var cloudSyncEnabled: Bool {
        get { cloudSyncPreference.isEnabled }
        set { cloudSyncPreference.isEnabled = newValue }
    }

    let cloudSyncPreference = CloudSyncPreference()

    private func cloudSyncEnabledDidChange(to enabled: Bool) {
        ServerStatusTracker.shared.clearBackendStatus()
        cloudSyncCoordinator.followPreference()
        requestPushScheduleSync()
        if enabled {
            pushCoordinator.forgetUploads()
            startRevisionPolling()
            #if os(iOS)
            scheduleLiveActivityRefresh()
            #endif
        } else {
            stopRevisionPolling()
            #if os(iOS)
            Task { @MainActor in await liveActivityCoordinator.endAll() }
            #endif
        }
    }

    /// Mac-only: where the "open in Moodle" actions route to. The iPad
    /// Moodle app installed via Mac App Store registers `moodlemobile://`
    /// too, so users who installed it can opt into the deep-link path.
    var macMoodleOpenTarget: MoodleOpenTarget = Defaults[.macMoodleOpenTarget] {
        didSet { Defaults[.macMoodleOpenTarget] = macMoodleOpenTarget }
    }

    var invertSliderDirection: Bool = Defaults[.invertSliderDirection] {
        didSet { Defaults[.invertSliderDirection] = invertSliderDirection }
    }

    var showAbsoluteAssignmentTime: Bool = Defaults[.showAbsoluteAssignmentTime] {
        didSet { Defaults[.showAbsoluteAssignmentTime] = showAbsoluteAssignmentTime }
    }

    var alwaysShowAllPeriods: Bool = Defaults[.alwaysShowAllPeriods] {
        didSet { Defaults[.alwaysShowAllPeriods] = alwaysShowAllPeriods }
    }

    var showClassroomInClassTable: Bool = Defaults[.showClassroomInClassTable] {
        didSet { Defaults[.showClassroomInClassTable] = showClassroomInClassTable }
    }

    var flipToLibraryEnabled: Bool = Defaults[.flipToLibraryEnabled] {
        didSet { Defaults[.flipToLibraryEnabled] = flipToLibraryEnabled }
    }

    var courseCardFontScale: Double = CourseCardFontScaleStore().read() {
        didSet {
            let newSnapped = CourseCardFontScale.normalize(courseCardFontScale)
            let oldSnapped = CourseCardFontScale.normalize(oldValue)
            guard newSnapped != oldSnapped else { return }
            CourseCardFontScaleStore().write(newSnapped)
            let coordinator = widgetReloadCoordinator
            Task { @MainActor in
                coordinator.requestReload()
            }
        }
    }

    var visualPreset: VisualPreset = Defaults[.visualPreset] {
        didSet { Defaults[.visualPreset] = visualPreset }
    }

    var appLanguage: String = Defaults[.appLanguage] {
        didSet {
            guard appLanguage != oldValue else { return }
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

    var classroomMandarinDisplay: String = Defaults[.classroomMandarinDisplay] {
        didSet {
            guard classroomMandarinDisplay != oldValue else { return }
            let valid: Set<String> = ["original", "pinyin", "translated"]
            if !valid.contains(classroomMandarinDisplay) {
                classroomMandarinDisplay = "original"
                return
            }
            Defaults[.classroomMandarinDisplay] = classroomMandarinDisplay
            relabelAllCachedCourses()
        }
    }

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
                AppLogger.captureError(error, context: ["phase": "configuredTabs.encode"])
            }
        }
    }

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
