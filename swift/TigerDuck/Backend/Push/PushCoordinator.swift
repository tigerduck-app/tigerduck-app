#if canImport(ActivityKit)
import ActivityKit
#endif
import Foundation
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif
import UserNotifications
import os

nonisolated enum FullSyncOutcome: Equatable, Sendable {
    case synced
    case failed
    case skipped
}

protocol PushTokenSource: AnyObject {
    var forwardToken: ((Data) -> Void)? { get set }
    var forwardError: ((Error) -> Void)? { get set }
    var onSyncTrigger: (() async -> FullSyncOutcome)? { get set }
}

struct PushDiagnostic: Sendable {
    let isStarted: Bool
    let liveActivitiesEnabled: Bool
    let notificationAuthStatus: UNAuthorizationStatus
    let registration: PushRegistrationSnapshot
    let resolvedServerURL: URL
    let uuid: String
}

///
@MainActor
final class PushCoordinator {
    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    let ledger: SendLedger
    let registration: PushRegistrationService
    private let uploads: BackendUploads
    #if os(iOS)
    private let relay: PushTokenRelay
    #endif
    let scheduleSync: ScheduleSyncService

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Coord")

    private var run = RunState()

    /// Whether the push stack was started, and stopped by a sign-out since.
    private struct RunState {
        var isStarted = false
        var stoppedBySignOut = false
    }
    private let isProtectedDataAvailable: @MainActor () -> Bool

    init(
        identity: PushIdentity = .loadOrCreate(),
        apiClient: PushAPIClient? = nil,
        authTokenManager: AuthTokenManager? = nil,
        ledger: SendLedger? = nil,
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil
    ) {
        self.ledger = ledger ?? SendLedger()
        self.identity = identity
        #if os(iOS)
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { UIApplication.shared.isProtectedDataAvailable }
        #else
        self.isProtectedDataAvailable = isProtectedDataAvailable ?? { true }
        #endif
        let resolvedClient = apiClient
            ?? authTokenManager.map { PushAPIClient(backend: BackendClient(auth: $0.backendAuth)) } ?? PushAPIClient()
        self.apiClient = resolvedClient
        self.uploads = BackendUploads(client: resolvedClient, ledger: self.ledger)
        self.registration = PushRegistrationService(
            identity: identity,
            apiClient: resolvedClient,
            deviceClass: PushDeviceClass.resolvedForBuild
        )
        #if os(iOS)
        self.relay = PushTokenRelay(registration: registration)
        #endif
        self.scheduleSync = ScheduleSyncService(
            identity: identity,
            apiClient: resolvedClient,
            ledger: self.ledger
        )
    }

    func bindTokenForwarding(_ appDelegate: some PushTokenSource) {
        appDelegate.forwardToken = { [weak self] data in
            guard let self else { return }
            scheduleSync.forgetAcceptedList()
            Task { await self.registration.update(deviceToken: data) }
        }
        appDelegate.forwardError = { [weak self] error in
            guard let self else { return }
            Task { await self.registration.registrationFailed(error) }
        }
    }

    func enable(requestPermission: Bool = false) {
        let firstStart = !run.isStarted
        if firstStart {
            run.isStarted = true
            #if os(iOS)
            relay.start()
            #endif
        }
        logger.info("enabling push stack (firstStart=\(firstStart, privacy: .public), requestPermission=\(requestPermission, privacy: .public))")

        Task { @MainActor in
            if requestPermission {
                let granted = (try? await UNUserNotificationCenter.current()
                    .requestAuthorization(options: [.alert, .sound, .badge])) ?? false
                logger.info("notification authorization granted=\(granted, privacy: .public)")
            }
            // `registerForRemoteNotifications` is safe in any permission state
            // and yields a token only when authorized. Calling it on every enable
            // lets a later grant reach token forwarding with no extra hook.
            #if os(iOS)
            UIApplication.shared.registerForRemoteNotifications()
            #elseif os(macOS)
            // macOS is passive — no APNs push. Register the device UUID
            // with the backend (no push token) so it appears in the sync
            // log. The Mac client syncs on foreground only.
            await registration.registerPassiveDevice()
            #endif
        }
    }

    static let unchangedCredentialsInterval = BackendUploads.unchangedCredentialsInterval

    func updateCredentialsIfDue(moodleToken: String, moodlePrivateToken: String?) async throws {
        try await uploads.updateCredentialsIfDue(moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken)
    }

    func fetchRevision() async throws -> Int {
        try await apiClient.fetchRevision()
    }

    func fetchFullSync() async throws -> [String: Any] {
        try await apiClient.fetchFullSync()
    }

    func fetchChanges(sinceRevision: Int) async throws -> PushAPI.SyncChangesPage {
        try await apiClient.fetchChanges(sinceRevision: sinceRevision)
    }

    func patchAssignmentOverride(
        moodleAssignmentId: String, localStatus: String, madeAt stamp: Date
    ) async throws -> PushAPI.AssignmentOverrideResponse {
        try await apiClient.patchAssignmentOverride(moodleAssignmentId: moodleAssignmentId, localStatus: localStatus, madeAt: stamp)
    }

    func patchCourseOverride(
        courseKey: String, colorHex: String? = nil, customName: String? = nil, locale: String? = nil,
        ignoreAssignments: Bool? = nil, moodleCourseId: Int? = nil, madeAt stamp: Date
    ) async throws -> PushAPI.CourseOverrideResponse {
        try await apiClient.patchCourseOverride(
            courseKey: courseKey, colorHex: colorHex, customName: customName, locale: locale,
            ignoreAssignments: ignoreAssignments, moodleCourseId: moodleCourseId, madeAt: stamp
        )
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt stamp: Date? = nil) async throws {
        try await apiClient.uploadCourses(request, addedAt: stamp)
    }

    nonisolated static let unchangedUploadInterval = BackendUploads.unchangedUploadInterval

    var onCoursesUploaded: @MainActor () -> Void {
        get { uploads.onCoursesUploaded }
        set { uploads.onCoursesUploaded = newValue }
    }

    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest, semester: String, resend: Bool = false, addedAt stamp: Date? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        try await uploads.uploadCoursesIfChanged(
            request, semester: semester, resend: resend, addedAt: stamp, isCurrent: isCurrent
        )
    }

    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest, isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        try await uploads.uploadAssignmentsIfChanged(request, isCurrent: isCurrent)
    }

    func forgetUploads(semester: String? = nil) {
        uploads.forgetUploads(semester: semester)
    }

    var holdsUnsentCourseUploads: Bool { uploads.holdsUnsentCourseUploads }

    nonisolated static func fingerprint(of request: PushAPI.CourseUploadRequest) -> String {
        BackendUploads.fingerprint(of: request)
    }

    func deleteAllCourses(semester: String? = nil, madeAt stamp: Date) async throws {
        try await apiClient.deleteAllCourses(semester: semester, madeAt: stamp)
    }

    func deleteCourse(courseKey: String, madeAt stamp: Date) async throws {
        try await apiClient.deleteCourse(courseKey: courseKey, madeAt: stamp)
    }

    /// A new session or device registration may come to a server without this device's schedule,
    /// so the next list goes up even when unchanged.
    func refreshRegistrationAfterAuth() {
        scheduleSync.forgetAcceptedList()
        if run.stoppedBySignOut {
            run.stoppedBySignOut = false
            enable()
        }
        Task { await registration.registerAgain() }
    }

    func registerAgainIfGaveUp() {
        Task { await registration.registerAgainIfGaveUp() }
    }

    func currentSnapshot() async -> PushDiagnostic {
        let reg = await registration.snapshot()
        #if os(iOS)
        let liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        #else
        let liveActivitiesEnabled = false
        #endif
        let notificationStatus = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        return PushDiagnostic(
            isStarted: run.isStarted,
            liveActivitiesEnabled: liveActivitiesEnabled,
            notificationAuthStatus: notificationStatus,
            registration: reg,
            resolvedServerURL: PushServerConfig.resolveServerURL(),
            uuid: identity.uuid
        )
    }

    @discardableResult
    func disable() async -> Bool {
        guard run.isStarted else { return false }
        run.isStarted = false
        run.stoppedBySignOut = true
        ledger.forget(SendLedger.Channel.credentials)
        logger.info("disabling push stack")

        #if os(iOS)
        relay.stop()
        #endif
        await scheduleSync.cancelRequest()
        await scheduleSync.awaitInflight()
        scheduleSync.forgetAcceptedList()
        return await registration.unregister()
    }

    #if os(iOS)
    func registerLiveActivityUpdateToken(
        _ registrationPayload: LiveActivityUpdateTokenRegistration
    ) async {
        await registration.registerLiveActivityUpdateToken(registrationPayload)
    }
    #endif

    func requestSync(
        debounceMs: Int = 400,
        inputsBuilder: @escaping @MainActor () -> ScheduleSyncService.Inputs
    ) {
        scheduleSync.request(after: .milliseconds(debounceMs), inputsBuilder: inputsBuilder)
    }

    func syncNow(inputsBuilder: @MainActor () -> ScheduleSyncService.Inputs) async {
        guard await apiClient.hasAuthSession(), run.isStarted else { return }
        guard isProtectedDataAvailable() else { return }
        scheduleSync.sync(inputs: inputsBuilder())
        await scheduleSync.awaitInflight()
    }

    nonisolated static func assertEnvConsistency() {
        PushServerConfig.assertEnvConsistency()
    }
}
