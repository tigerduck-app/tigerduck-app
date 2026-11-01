import Defaults
import SwiftUI

@MainActor
@Observable
final class AppEnvironment {
    var hasCompletedOnboarding = Defaults[.hasCompletedOnboarding]
    var didSkipMacLogin = false

    let preferences: AppPreferences
    let router = AppRouter()
    let library = LibraryAccountStatus()
    let authService: AuthService
    let updateNotifyCoordinator = UpdateNotifyCoordinator()
    @ObservationIgnored let backend: AppBackend
    @ObservationIgnored private(set) var sync: AppSyncParts!

    var authTokenManager: AuthTokenManager { backend.authTokenManager }
    var pushCoordinator: PushCoordinator { backend.pushCoordinator }
    var cloudSyncCoordinator: CloudSyncCoordinator { backend.cloudSyncCoordinator }
    var cloudSyncPreference: CloudSyncPreference { backend.cloudSyncPreference }
    var firstPullGate: FirstPullGate { backend.firstPullGate }
    var localEdits: LocalEdits { backend.localEdits }
    var poller: RevisionPoller { backend.poller }
    var edits: EditSender { backend.edits }
    var uploads: SchoolDataUploader { backend.uploads }
    var holidays: HolidaySettingSender { backend.holidays }
    var relabeler: CourseRelabeler { backend.relabeler }
    var feed: ChangeFeedPull { sync.feed }
    var fullSync: FullSyncRunner { sync.fullSync }
    var conflicts: SyncConflicts { sync.conflicts }
    var pushSchedule: PushScheduleSync { sync.pushSchedule }
    var activation: SceneActivation { sync.activation }
    #if os(iOS)
    var liveActivity: LiveActivityRefresher { sync.liveActivity }
    var notificationSettings: NotificationSettingsSyncer { sync.notificationSettings }
    #endif

    var cloudSyncEnabled: Bool { cloudSyncPreference.isEnabled }

    /// The TigerSync switch, which keeps each flip for the sign-in it was made in.
    var cloudSyncSwitch: Binding<Bool> {
        Binding(get: { self.cloudSyncEnabled },
                set: { self.cloudSyncPreference.setEnabled($0, for: self.authService.session.currentSignIn) })
    }

    var signOutCheck: SignOutCheck { SignOutCheck(app: self) }

    var versionGate: APIVersionGate { .shared }

    init() {
        let purge = FreshInstallKeychainPurge.runIfFreshInstall()
        if purge != .itemsLeft { BareKeychainItemMoveMigration.runIfNeeded() }
        DemoAccount.resumeAtLaunch(in: .school)

        let authService = AuthService(session: .school)
        self.authService = authService
        let identity = PushIdentity.loadOrCreate()
        let atm = Self.tokenManager(after: purge, deviceUUID: identity.uuid, signIn: authService.session.currentSignIn)
        let pushCoordinator = PushCoordinator(identity: identity, authTokenManager: atm, signIns: authService.session.signIns)
        let cloudSync = CloudSyncCoordinator(
            pushCoordinator: pushCoordinator,
            addedCourseUpload: { SchoolDataUploader.addedCourseUpload(semester: $0, courseNo: $1) },
            uploadsCourses: { SyncPolicy.current.uploadsCourses },
            account: authService.session
        )
        CloudSyncCoordinator.registerShared(cloudSync)
        preferences = AppPreferences()
        backend = AppBackend(authTokenManager: atm, pushCoordinator: pushCoordinator, cloudSync: cloudSync,
                             account: authService.session)
        sync = AppSyncParts(app: self)

        #if os(iOS)
        if purge.isFreshInstall {
            updateNotifyCoordinator.seedWhatsNewOnFreshInstall()
        }
        liveActivity.observePreferenceChanges()
        holidays.onChange = { [weak self] in self?.liveActivity.scheduleRefresh() }
        #endif

        runPendingMigrations()
        wire(atm)
    }

    private static func tokenManager(
        after _: FreshInstallKeychainPurge.Outcome, deviceUUID: String, signIn: SignIn
    ) -> AuthTokenManager {
        AuthTokenManager(deviceUUID: deviceUUID, storedFor: signIn)
    }

    private func wire(_ atm: AuthTokenManager) {
        Task { [weak self] in
            await atm.setRefreshFailedHandler { [weak self, weak atm] signIn in
                await self?.attemptBackendRelogin(replacing: await atm?.storedAccessToken, for: signIn) ?? false
            }
            await atm.setSignInAgainHandler { [weak self] refused, signIn in
                await self?.attemptBackendRelogin(replacing: refused, for: signIn) ?? false
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
            authService.backend.retryDepartingUnregisterBeforeSigningIn { [pushCoordinator] in
                await atm.retryDepartingUnregister { await pushCoordinator.registration.unregisterDevice(at: $0) }
            }
        }

        authService.authTokenManager = atm
        authService.onV3SignedIn = { [weak self] in
            guard let self else { return }
            pushCoordinator.refreshRegistrationAfterAuth()
            pushSchedule.requestSync()
            #if os(iOS)
            NotificationSettingsSync.seedSyncedCopyOnSignIn(
                from: .init(from: liveActivity.preferences), for: authService.session.currentSignIn
            )
            notificationSettings.reconcile()
            #endif
        }
        authService.signOutStoredAccount = { [weak self] in
            guard let self else { return }
            await SignOutPlan.school(self).run()?.value
        }
        authService.clearAllCachedPages = { await AccountSignOutCleanup.clearAllCachedPages() }

        cloudSyncPreference.onChange { [weak self] enabled in
            self?.cloudSyncEnabledDidChange(to: enabled)
        }
        preferences.willChangeLanguage = { [weak self] in self?.activation.cancelRefresh() }
        preferences.onCourseLabelsChange = { [weak self] in
            guard let self else { return }
            relabeler.relabelAll(for: authService.session.currentSignIn)
        }

        CourseUpload.courseUploader = { [weak self] courses, semester, kind, signIn in
            self?.uploads.uploadCourses(courses, semester: semester, asRoster: kind.asRoster, resend: kind.resend, for: signIn)
        }
        AssignmentAnswers.assignmentUploader = { [weak self] request, signIn in
            self?.uploads.uploadAssignments(request, for: signIn)
        }
        poller.poll = { [weak self] in await self?.feed.pollRevision() ?? .unchanged }
        pushCoordinator.onCoursesUploaded = { [weak self] in self?.cloudSyncCoordinator.courseUploadLanded() }
        CourseColorStore.shared.onLateMoodleColors = { [weak self] in
            Task { await self?.fullSync.sync(followUpIfBusy: true) }
        }

        // Skip "system": apply() would remove AppleLanguages, wiping the per-app override iOS
        // Settings writes there.
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

    private func attemptBackendRelogin(replacing refused: String?, for signIn: SignIn) async -> Bool {
        guard await authService.reloginToBackend(replacing: refused, for: signIn) else { return false }
        pushCoordinator.refreshRegistrationAfterAuth()
        return true
    }

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
