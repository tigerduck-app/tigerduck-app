import Defaults
import SwiftUI

/// The composition root: the account, the backend sync and the app's preferences, built once per
/// process. On iPhone it is built only once protected data can be read
/// (docs/decisions/0024-launch-before-first-unlock.md).
@MainActor
@Observable
final class AppEnvironment {
    var hasCompletedOnboarding = Defaults[.hasCompletedOnboarding]
    var didSkipMacLogin = false

    let preferences: AppPreferences
    let router = AppRouter()
    let library = LibraryAccountStatus()
    let authService: AuthService
    let authTokenManager: AuthTokenManager
    let pushCoordinator: PushCoordinator
    let cloudSyncCoordinator: CloudSyncCoordinator
    let cloudSyncPreference = CloudSyncPreference()
    let updateNotifyCoordinator = UpdateNotifyCoordinator()

    @ObservationIgnored let syncTarget: SyncTarget
    @ObservationIgnored let localEdits: LocalEdits
    @ObservationIgnored let poller: RevisionPoller
    @ObservationIgnored let edits: EditSender
    @ObservationIgnored let uploads: SchoolDataUploader
    @ObservationIgnored let holidays: HolidaySettingSender
    @ObservationIgnored let relabeler = CourseRelabeler()
    @ObservationIgnored private(set) lazy var feed = ChangeFeedPull(app: self)
    @ObservationIgnored private(set) lazy var fullSync = FullSyncRunner(app: self)
    @ObservationIgnored private(set) lazy var conflicts = SyncConflicts(app: self)
    @ObservationIgnored private(set) lazy var pushSchedule = PushScheduleSync(app: self)
    @ObservationIgnored private(set) lazy var activation = SceneActivation(app: self)
    #if os(iOS)
    @ObservationIgnored private(set) lazy var liveActivity = LiveActivityRefresher(app: self)
    @ObservationIgnored private(set) lazy var notificationSettings = NotificationSettingsSyncer(
        authTokenManager: authTokenManager, preferences: liveActivity.preferences
    )
    #endif

    var cloudSyncEnabled: Bool {
        get { cloudSyncPreference.isEnabled }
        set { cloudSyncPreference.isEnabled = newValue }
    }

    var signOutCheck: SignOutCheck { SignOutCheck(app: self) }

    var versionGate: APIVersionGate { .shared }

    init() {
        let isFreshInstall = FreshInstallKeychainPurge.runIfFreshInstall()
        // After the purge, which deletes a reinstall's bare items, and before AuthService reads them.
        // A purge left for the next launch keeps them from moving.
        if Defaults[.appHasBeenInstalled] { BareKeychainItemMoveMigration.runIfNeeded() }

        let authService = AuthService(session: .school)
        self.authService = authService
        let identity = PushIdentity.loadOrCreate()
        let atm = AuthTokenManager(deviceUUID: identity.uuid)
        authTokenManager = atm
        let pushCoordinator = PushCoordinator(identity: identity, authTokenManager: atm)
        self.pushCoordinator = pushCoordinator
        let cloudSync = CloudSyncCoordinator(
            pushCoordinator: pushCoordinator,
            addedCourseUpload: { SchoolDataUploader.addedCourseUpload(semester: $0, courseNo: $1) },
            uploadsCourses: { SyncPolicy.current.uploadsCourses },
            account: authService.session
        )
        cloudSyncCoordinator = cloudSync
        CloudSyncCoordinator.registerShared(cloudSync)
        preferences = AppPreferences()
        let poller = RevisionPoller()
        self.poller = poller
        let syncTarget = SyncTarget(account: authService.session)
        self.syncTarget = syncTarget
        let localEdits = LocalEdits(account: authService.session)
        self.localEdits = localEdits
        edits = EditSender(coordinator: cloudSync, push: pushCoordinator, poller: poller, localEdits: localEdits)
        uploads = SchoolDataUploader(account: authService.session, target: syncTarget, backend: pushCoordinator)
        holidays = HolidaySettingSender(account: authService.session, push: pushCoordinator, poller: poller)

        #if os(iOS)
        if isFreshInstall {
            updateNotifyCoordinator.seedWhatsNewOnFreshInstall()
        }
        // Built before the migrations, so a preference they change reaches the Live Activity.
        _ = liveActivity
        holidays.onChange = { [weak self] in self?.liveActivity.scheduleRefresh() }
        #endif

        runPendingMigrations()
        wire(atm)
    }

    private func wire(_ atm: AuthTokenManager) {
        Task { [weak self] in
            await atm.setRefreshFailedHandler { [weak self, weak atm] in
                await self?.attemptBackendRelogin(replacing: await atm?.storedAccessToken) ?? false
            }
            await atm.setSignInAgainHandler { [weak self] refused in
                await self?.attemptBackendRelogin(replacing: refused) ?? false
            }
            await atm.setNoSessionHandler { [weak self] in
                await self?.authService.ensureBackendSignedIn()
            }
        }

        if hasCompletedOnboarding {
            pushCoordinator.enable()
        }
        if SignOutCheck.retriesDepartingUnregister(
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
            pushCoordinator.refreshRegistrationAfterAuth()
            pushSchedule.requestSync()
            #if os(iOS)
            NotificationSettingsSync.accountSignedIn(local: .init(from: liveActivity.preferences))
            notificationSettings.reconcile()
            #endif
        }
        authService.signOutStoredAccount = { [weak self] in
            guard let self else { return }
            await SignOutPlan.school(self).run()?.value
        }
        authService.forgetPages = { await AuthService.forgetSchoolPages() }

        cloudSyncPreference.onChange { [weak self] enabled in
            self?.cloudSyncEnabledDidChange(to: enabled)
        }
        preferences.onLanguageChange = { [weak self] in self?.activation.cancelRefresh() }
        preferences.onCourseLabelsChange = { [weak self] in self?.relabeler.relabelAll() }

        CourseFetch.courseUploader = { [weak self] courses, semester, asRoster, resend in
            self?.uploads.uploadCourses(courses, semester: semester, asRoster: asRoster, resend: resend)
        }
        AssignmentFetch.assignmentUploader = { [weak self] request in
            self?.uploads.uploadAssignments(request)
        }
        poller.poll = { [weak self] in await self?.feed.pollRevision() ?? .unchanged }
        pushCoordinator.onCoursesUploaded = { [weak self] in self?.cloudSyncCoordinator.courseUploadLanded() }

        // Apply a stored in-app language override at launch so lookups use it. Skip "system":
        // apply() would remove AppleLanguages, wiping the per-app override iOS Settings writes there.
        if preferences.appLanguage != LanguageManager.system {
            LanguageManager.apply(preferences.appLanguage)
        }
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        Defaults[.hasCompletedOnboarding] = true
        pushCoordinator.enable()
        activation.refresh()
        Task { await TLSPinDocumentFetcher.shared.fetchIfDue() }
    }

    private func attemptBackendRelogin(replacing refused: String?) async -> Bool {
        guard await authService.reloginToBackend(replacing: refused) else { return false }
        pushCoordinator.refreshRegistrationAfterAuth()
        return true
    }

    /// Runs the one-time upgrades in `Migrations/`, once per launch.
    private func runPendingMigrations() {
        SemesterAttributionCacheMigration.runIfNeeded()
        SyncedAccountSeedMigration.runIfNeeded(signedIn: authService.hasStoredCredentials)
        CourseColorPickSeedMigration.runIfNeeded()
        StoredPasswordLatchRetryMigration.runIfNeeded()
        LibraryPasswordLatchRetryMigration.runIfNeeded()
        DepartingSessionListMigration.runIfNeeded()
        if CustomAccentContrastMigration.runIfNeeded() {
            preferences.accentColorHex = Defaults[.accentColorHex]
        }
        #if os(iOS)
        BulletinPushOptOutMigration.runIfNeeded()
        if DefaultTabsPinMigration.runIfNeeded() {
            preferences.configuredTabs = AppPreferences.decodeConfiguredTabs(Defaults[.configuredTabsData])
                ?? AppFeature.defaultTabs
        }
        if LibraryTabAddMigration.runIfNeeded() {
            preferences.configuredTabs = AppPreferences.decodeConfiguredTabs(Defaults[.configuredTabsData])
                ?? AppFeature.defaultTabs
        }
        LiveActivitySnapshotPurgeMigration.runIfNeeded()
        NotificationSettingsSyncedSeedMigration.runIfNeeded(
            current: .init(from: liveActivity.preferences),
            signedIn: authService.hasStoredCredentials
        )
        if FlipToLibraryDefaultOffMigration.runIfNeeded() {
            preferences.flipToLibraryEnabled = Defaults[.flipToLibraryEnabled]
        }
        #endif
        Task(priority: .utility) { @MainActor in
            #if os(iOS)
            await PendingReminderPurgeMigration.runIfNeeded()
            NotificationSettingsSeedMigration.runIfNeeded { onSettled in
                self.notificationSettings.reconcile(onSettled: onSettled)
            }
            await MoodleDownloadProtectMigration.runIfNeeded(
                root: MoodleFiles.shared.moodleFilesDir,
                isProtectedDataAvailable: UIApplication.shared.isProtectedDataAvailable
            )
            #endif
        }
    }

    private func cloudSyncEnabledDidChange(to enabled: Bool) {
        ServerStatusTracker.shared.clearBackendStatus()
        cloudSyncCoordinator.followPreference()
        pushSchedule.requestSync()
        if enabled {
            pushCoordinator.forgetUploads()
            feed.startPolling()
            #if os(iOS)
            liveActivity.scheduleRefresh()
            #endif
        } else {
            feed.stopPolling()
            #if os(iOS)
            Task { @MainActor in await liveActivity.coordinator.endAll() }
            #endif
        }
    }
}
