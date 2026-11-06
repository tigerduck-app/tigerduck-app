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

    private struct RunState {
        var isStarted = false
        var waitsForSignIn = false
    }
    private let isProtectedDataAvailable: @MainActor () -> Bool

    init(
        identity: PushIdentity = .loadOrCreate(),
        apiClient: PushAPIClient? = nil,
        authTokenManager: AuthTokenManager? = nil,
        ledger: SendLedger? = nil,
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil,
        signIns: SignInSeries
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
            signIns: signIns,
            deviceClass: PushDeviceClass.resolvedForBuild
        )
        #if os(iOS)
        self.relay = PushTokenRelay(registration: registration)
        #endif
        self.scheduleSync = ScheduleSyncService(
            identity: identity,
            apiClient: resolvedClient,
            signIns: signIns,
            ledger: self.ledger
        )
    }

    func bindTokenForwarding(_ appDelegate: some PushTokenSource) {
        appDelegate.forwardToken = { [weak self] data in
            guard let self else { return }
            scheduleSync.resendScheduleOnNextSync()
            Task { await self.registration.update(deviceToken: data) }
        }
        appDelegate.forwardError = { [weak self] error in
            guard let self else { return }
            Task { await self.registration.registrationFailed(error) }
        }
    }

    func enable(requestPermission: Bool = false) {
        if registration.servesDemoAccount { run.waitsForSignIn = true; return }
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
            await registerWithPushService()
        }
    }

    private func registerWithPushService() async {
        #if os(iOS)
        UIApplication.shared.registerForRemoteNotifications()
        #elseif os(macOS)
        await registration.registerPassiveDevice()
        #endif
    }

    func updateCredentialsIfDue(moodleToken: String, moodlePrivateToken: String?, for signIn: SignIn) async throws {
        try await uploads.updateCredentialsIfDue(moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken, for: signIn)
    }

    func fetchRevision(for signIn: SignIn) async throws -> Int {
        try await apiClient.fetchRevision(for: signIn)
    }

    func fetchFullSync(for signIn: SignIn) async throws -> [String: Any] {
        try await apiClient.fetchFullSync(for: signIn)
    }

    func fetchChanges(sinceRevision: Int, for signIn: SignIn) async throws -> PushAPI.SyncChangesPage {
        try await apiClient.fetchChanges(sinceRevision: sinceRevision, for: signIn)
    }

    func patchAssignmentOverride(
        moodleAssignmentId: String, localStatus: String, madeAt stamp: Date, for signIn: SignIn
    ) async throws -> PushAPI.AssignmentOverrideResponse {
        try await apiClient.patchAssignmentOverride(
            moodleAssignmentId: moodleAssignmentId, localStatus: localStatus, madeAt: stamp, for: signIn
        )
    }

    func patchCourseOverride(
        courseKey: String, colorHex: String? = nil, customName: String? = nil, locale: String? = nil,
        ignoreAssignments: Bool? = nil, moodleCourseId: Int? = nil, madeAt stamp: Date, for signIn: SignIn
    ) async throws -> PushAPI.CourseOverrideResponse {
        try await apiClient.patchCourseOverride(
            courseKey: courseKey, colorHex: colorHex, customName: customName, locale: locale,
            ignoreAssignments: ignoreAssignments, moodleCourseId: moodleCourseId, madeAt: stamp, for: signIn
        )
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt stamp: Date? = nil, for signIn: SignIn) async throws {
        try await apiClient.uploadCourses(request, addedAt: stamp, for: signIn)
    }

    nonisolated static let unchangedUploadInterval = BackendUploads.unchangedUploadInterval

    var onCoursesUploaded: @MainActor () -> Void {
        get { uploads.onCoursesUploaded }
        set { uploads.onCoursesUploaded = newValue }
    }

    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest, semester: String, resend: Bool = false, addedAt stamp: Date? = nil,
        for signIn: SignIn, while wanted: @escaping @MainActor () -> Bool = { true }
    ) async throws -> Bool {
        try await uploads.uploadCoursesIfChanged(
            request, semester: semester, resend: resend, addedAt: stamp, for: signIn, while: wanted
        )
    }

    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest, for signIn: SignIn,
        while wanted: @escaping @MainActor () -> Bool = { true }
    ) async throws -> Bool {
        try await uploads.uploadAssignmentsIfChanged(request, for: signIn, while: wanted)
    }

    func forgetUploads(semester: String? = nil) {
        uploads.forgetUploads(semester: semester)
    }

    var holdsUnsentCourseUploads: Bool { uploads.holdsUnsentCourseUploads }

    nonisolated static func fingerprint(of request: PushAPI.CourseUploadRequest) -> String {
        BackendUploads.fingerprint(of: request)
    }

    func deleteAllCourses(semester: String? = nil, madeAt stamp: Date, for signIn: SignIn) async throws {
        try await apiClient.deleteAllCourses(semester: semester, madeAt: stamp, for: signIn)
    }

    func deleteCourse(courseKey: String, kind: PushAPI.CourseDeleteKind?, madeAt stamp: Date, for signIn: SignIn) async throws {
        try await apiClient.deleteCourse(courseKey: courseKey, kind: kind, madeAt: stamp, for: signIn)
    }

    func refreshRegistrationAfterAuth() {
        scheduleSync.resendScheduleOnNextSync()
        if run.waitsForSignIn {
            run.waitsForSignIn = false
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
        run.waitsForSignIn = true
        ledger.forget(SendLedger.Channel.credentials)
        logger.info("disabling push stack")

        #if os(iOS)
        relay.stop()
        #endif
        await scheduleSync.cancelRequest()
        await scheduleSync.awaitInflight()
        scheduleSync.resendScheduleOnNextSync()
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
        scheduleSync.sync(building: inputsBuilder)
        await scheduleSync.awaitInflight()
    }

    nonisolated static func assertEnvConsistency() {
        PushServerConfig.assertEnvConsistency()
    }
}
