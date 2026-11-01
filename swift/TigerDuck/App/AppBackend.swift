import Foundation

@MainActor
struct AppBackend {
    let authTokenManager: AuthTokenManager
    let pushCoordinator: PushCoordinator
    let cloudSyncCoordinator: CloudSyncCoordinator
    let cloudSyncPreference = CloudSyncPreference()
    let poller = RevisionPoller()
    let firstPullGate: FirstPullGate
    let localEdits: LocalEdits
    let edits: EditSender
    let uploads: SchoolDataUploader
    let holidays: HolidaySettingSender
    let relabeler = CourseRelabeler()

    init(authTokenManager: AuthTokenManager, pushCoordinator: PushCoordinator, cloudSync: CloudSyncCoordinator,
         account: AccountSession) {
        self.authTokenManager = authTokenManager
        self.pushCoordinator = pushCoordinator
        cloudSyncCoordinator = cloudSync
        firstPullGate = FirstPullGate()
        localEdits = LocalEdits()
        edits = EditSender(
            coordinator: cloudSync, push: pushCoordinator, poller: poller, localEdits: localEdits, account: account
        )
        uploads = SchoolDataUploader(target: firstPullGate, backend: pushCoordinator)
        holidays = HolidaySettingSender(account: account, push: pushCoordinator, poller: poller)
    }
}

@MainActor
final class AppSyncParts {
    private unowned let app: AppEnvironment
    private(set) lazy var feed = ChangeFeedPull(app: app)
    private(set) lazy var fullSync = FullSyncRunner(app: app)
    private(set) lazy var conflicts = SyncConflicts(app: app)
    private(set) lazy var pushSchedule = PushScheduleSync(app: app)
    private(set) lazy var activation = SceneActivation(app: app)
    #if os(iOS)
    private(set) lazy var liveActivity = LiveActivityRefresher(app: app)
    private(set) lazy var notificationSettings = NotificationSettingsSyncer(
        authTokenManager: app.authTokenManager, preferences: liveActivity.preferences
    )
    #endif

    init(app: AppEnvironment) {
        self.app = app
    }
}
