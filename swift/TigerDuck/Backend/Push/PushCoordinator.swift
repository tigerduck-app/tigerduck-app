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
    #if os(iOS)
    private let relay: PushTokenRelay
    #endif
    let scheduleSync: ScheduleSyncService

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Coord")

    private var run = RunState()

    /// Whether the push stack was started, and stopped by a sign-out since, and the debounced
    /// schedule sync waiting to run.
    private struct RunState {
        var isStarted = false
        var stoppedBySignOut = false
        var pendingSyncTask: Task<Void, Never>?
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
        let resolvedClient: PushAPIClient
        if let apiClient {
            resolvedClient = apiClient
        } else if let atm = authTokenManager {
            resolvedClient = PushAPIClient(backend: BackendClient(auth: atm.backendAuth))
        } else {
            resolvedClient = PushAPIClient()
        }
        self.apiClient = resolvedClient
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

    static let unchangedCredentialsInterval: TimeInterval = 3600

    /// Unchanged Moodle tokens go again after an hour, as the backend's copy may have expired.
    func updateCredentialsIfDue(moodleToken: String, moodlePrivateToken: String?) async throws {
        let client = apiClient
        let ledger = ledger
        let fingerprint = SendLedger.fingerprint(of: [moodleToken, moodlePrivateToken ?? ""])
        do {
            _ = try await ledger.send(
                SendLedger.Channel.credentials, fingerprint: fingerprint,
                resend: .after(Self.unchangedCredentialsInterval), isCurrent: { true }
            ) {
                let response = try await client.updateCredentials(
                    moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken
                )
                if !response.updated { throw CredentialsNotUpdatedError() }
            }
        } catch is CredentialsNotUpdatedError {}
    }

    private struct CredentialsNotUpdatedError: Error {}

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
        moodleAssignmentId: String,
        localStatus: String,
        madeAt stamp: Date
    ) async throws -> PushAPI.AssignmentOverrideResponse {
        try await apiClient.patchAssignmentOverride(
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus,
            madeAt: stamp
        )
    }

    func patchCourseOverride(
        courseKey: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil,
        ignoreAssignments: Bool? = nil,
        moodleCourseId: Int? = nil,
        madeAt stamp: Date
    ) async throws -> PushAPI.CourseOverrideResponse {
        try await apiClient.patchCourseOverride(
            courseKey: courseKey,
            colorHex: colorHex,
            customName: customName,
            locale: locale,
            ignoreAssignments: ignoreAssignments,
            moodleCourseId: moodleCourseId,
            madeAt: stamp
        )
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt stamp: Date? = nil) async throws {
        try await apiClient.uploadCourses(request, addedAt: stamp)
    }

    nonisolated static let unchangedUploadInterval: TimeInterval = 6 * 3600

    /// Runs after each course upload the backend took, for the edits that waited for its courses.
    var onCoursesUploaded: @MainActor () -> Void = {}

    /// An unchanged list goes again after six hours; an add or a resend goes whatever it holds.
    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest,
        semester: String,
        resend: Bool = false,
        addedAt stamp: Date? = nil,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let client = apiClient
        let always = resend || request.adds?.isEmpty == false
        let sent = try await ledger.send(
            SendLedger.Channel.courses(semester),
            fingerprint: Self.fingerprint(of: request),
            resend: always ? .always : .after(Self.unchangedUploadInterval),
            pausesAfterRefusal: true,
            isCurrent: isCurrent
        ) {
            try await client.uploadCourses(request, addedAt: stamp)
        }
        if sent { onCoursesUploaded() }
        return sent
    }

    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let client = apiClient
        return try await ledger.send(
            SendLedger.Channel.assignments, fingerprint: Self.fingerprint(of: request),
            resend: .after(Self.unchangedUploadInterval), pausesAfterRefusal: true, isCurrent: isCurrent
        ) {
            try await client.uploadAssignments(request)
        }
    }

    func forgetUploads(semester: String? = nil) {
        if let semester {
            ledger.forget(SendLedger.Channel.courses(semester))
        } else {
            ledger.forget(prefixes: [SendLedger.Channel.courses(""), SendLedger.Channel.assignments])
        }
    }

    var holdsUnsentCourseUploads: Bool {
        ledger.holdsUnsent(prefix: SendLedger.Channel.courses(""))
    }

    /// The order of the courses and the adds leave the fingerprint alone: an add goes whatever the
    /// ledger holds, and once it lands the backend holds the list it carried.
    nonisolated static func fingerprint(of request: PushAPI.CourseUploadRequest) -> String {
        SendLedger.fingerprint(of: PushAPI.CourseUploadRequest(
            courses: request.courses.sorted { $0.courseNo < $1.courseNo },
            rosterTerms: request.rosterTerms?.sorted()
        ))
    }

    nonisolated static func fingerprint(of request: PushAPI.AssignmentUploadRequest) -> String {
        SendLedger.fingerprint(of: PushAPI.AssignmentUploadRequest(
            assignments: request.assignments.sorted { $0.moodleAssignmentId < $1.moodleAssignmentId }
        ))
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
        run.pendingSyncTask?.cancel()
        await run.pendingSyncTask?.value
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
        run.pendingSyncTask?.cancel()
        run.pendingSyncTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(debounceMs))
            guard !Task.isCancelled else { return }
            #if os(iOS)
            guard UIApplication.shared.applicationState != .background else { return }
            #endif
            guard await self?.apiClient.hasAuthSession() == true else { return }
            let inputs = inputsBuilder()
            self?.scheduleSync.sync(inputs: inputs)
        }
    }

    func syncNow(inputsBuilder: @MainActor () -> ScheduleSyncService.Inputs) async {
        guard await apiClient.hasAuthSession(), run.isStarted else { return }
        guard isProtectedDataAvailable() else { return }
        scheduleSync.sync(inputs: inputsBuilder())
        await scheduleSync.awaitInflight()
    }

    // MARK: - Build-time env sanity

    /// Crashes Debug builds at launch when the resolved server URL does not
    /// match the APNs environment baked into the binary (or each other).
    /// Empty in Release builds: `assert` is stripped under `-O`, but working out
    /// its conditions would still read the Keychain twice before the first frame.
    /// Guards against the regression where someone flips `PushAPNsEnv` or
    /// `AppConstants.productionPushServerURL` without flipping the other,
    /// or seeds a stale UserDefaults override pointing the wrong way.
    nonisolated static func assertEnvConsistency() {
        #if DEBUG
        let resolved = PushServerConfig.resolveServerURL()
        let host = resolved.host?.lowercased() ?? ""
        let hostOK = DebugEndpointStore.currentOverride() != nil
            || host == "localhost"
            || host == "127.0.0.1"
            || PushServerConfig.isPrivateIPv4(host)
            || host == AppConstants.productionPushServerURL.host?.lowercased()
        let expectedEnv = "development"
        assert(
            hostOK,
            "Push env mismatch: \(expectedEnv) build resolved to \(resolved)"
        )
        assert(
            PushAPNsEnv.resolvedForBuild == expectedEnv,
            "Push env mismatch: build is \(expectedEnv) but PushAPNsEnv = \(PushAPNsEnv.resolvedForBuild)"
        )
        #endif
    }
}
