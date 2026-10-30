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
    let registration: PushRegistrationService
    #if os(iOS)
    private let relay: PushTokenRelay
    #endif
    let scheduleSync: ScheduleSyncService

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Coord")

    private var isStarted = false
    private var stoppedBySignOut = false
    private var pendingSyncTask: Task<Void, Never>?
    private let isProtectedDataAvailable: @MainActor () -> Bool

    init(
        identity: PushIdentity = .loadOrCreate(),
        apiClient: PushAPIClient? = nil,
        authTokenManager: AuthTokenManager? = nil,
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil
    ) {
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
            resolvedClient = PushAPIClient(
                authHeaderProvider: { await atm.authorizationHeader() }
            )
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
            apiClient: resolvedClient
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
        let firstStart = !isStarted
        if firstStart {
            isStarted = true
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

    private var acceptedMoodleCredentials: (fingerprint: Int, at: Date)?

    static func credentialsUpdateIsDue(
        accepted: (fingerprint: Int, at: Date)?,
        fingerprint: Int,
        now: Date
    ) -> Bool {
        guard let accepted, accepted.fingerprint == fingerprint else { return true }
        let age = now.timeIntervalSince(accepted.at)
        return age >= unchangedCredentialsInterval || age < 0
    }

    func updateCredentialsIfDue(moodleToken: String, moodlePrivateToken: String?) async throws {
        var hasher = Hasher()
        hasher.combine(moodleToken)
        hasher.combine(moodlePrivateToken)
        let fingerprint = hasher.finalize()
        let now = Date()
        guard Self.credentialsUpdateIsDue(
            accepted: acceptedMoodleCredentials, fingerprint: fingerprint, now: now
        ) else { return }
        let response = try await apiClient.updateCredentials(
            moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken
        )
        acceptedMoodleCredentials = response.updated ? (fingerprint, now) : nil
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
        moodleAssignmentId: String,
        localStatus: String
    ) async throws {
        try await apiClient.patchAssignmentOverride(
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus
        )
    }

    func patchCourseOverride(
        moodleId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil,
        ignoreAssignments: Bool? = nil,
        moodleCourseId: Int? = nil
    ) async throws -> PushAPI.CourseOverrideResponse {
        try await apiClient.patchCourseOverride(
            moodleId: moodleId,
            colorHex: colorHex,
            customName: customName,
            locale: locale,
            ignoreAssignments: ignoreAssignments,
            moodleCourseId: moodleCourseId
        )
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest) async throws {
        try await apiClient.uploadCourses(request)
    }

    nonisolated static let unchangedUploadInterval: TimeInterval = 6 * 3600

    private var uploads = UploadLedger()
    var clock: () -> Date = { Date() }
    private var lastUploads: [String: Task<Void, Never>] = [:]
    private var unfinishedUploads: [String: [Int]] = [:]

    nonisolated static func uploadIsDue(accepted: (fingerprint: Int, at: Date)?, fingerprint: Int, now: Date) -> Bool {
        guard let accepted, accepted.fingerprint == fingerprint else { return true }
        let age = now.timeIntervalSince(accepted.at)
        return age >= unchangedUploadInterval || age < 0
    }

    func uploadCoursesIfChanged(
        _ request: PushAPI.CourseUploadRequest,
        semester: String,
        resend: Bool = false,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let client = apiClient
        return try await uploadIfChanged(
            UploadLedger.courses(semester),
            fingerprint: Self.fingerprint(of: request),
            always: resend || !request.forceKeys.isEmpty,
            isCurrent: isCurrent
        ) {
            try await client.uploadCourses(request)
        }
    }

    func uploadAssignmentsIfChanged(
        _ request: PushAPI.AssignmentUploadRequest,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        let client = apiClient
        return try await uploadIfChanged(
            UploadLedger.assignments, fingerprint: Self.fingerprint(of: request), always: false,
            isCurrent: isCurrent
        ) {
            try await client.uploadAssignments(request)
        }
    }

    func uploadIfChanged(
        _ key: String,
        fingerprint: Int,
        always: Bool,
        isCurrent: @escaping @MainActor () -> Bool,
        send: @escaping @MainActor () async throws -> Void
    ) async throws -> Bool {
        let previous = lastUploads[key]
        let upload = Task { @MainActor [weak self] () async throws -> Bool in
            await previous?.value
            try Task.checkCancellation()
            guard let self, isCurrent() else { return false }
            let now = self.clock()
            if !always, self.uploads.isHeldBack(key, fingerprint: fingerprint, now: now) {
                // An unchanged resend in between cleared the failure, and this list is still unsent.
                self.uploads.recordFailure(key, fingerprint: fingerprint, startedIn: self.uploads.generation(of: key))
                return false
            }
            guard always || self.uploads.isDue(key, fingerprint: fingerprint, now: now) else {
                self.uploads.forgetFailure(key)
                return false
            }
            let started = self.uploads.generation(of: key)
            do {
                try await send()
            } catch {
                if !AppLogger.isCancellation(error), isCurrent() {
                    self.uploads.recordFailure(key, fingerprint: fingerprint, startedIn: started)
                    // A 401 is retried at once after signing in again, so it holds nothing back.
                    if case PushAPIError.httpStatus(let status, _, _) = error, status != 401 {
                        self.uploads.recordRefusal(key, fingerprint: fingerprint, at: self.clock(), startedIn: started)
                    }
                }
                throw error
            }
            self.uploads.record(key, fingerprint: fingerprint, at: now, startedIn: started)
            return true
        }
        let ended = Task<Void, Never> { _ = try? await upload.value }
        lastUploads[key] = ended
        unfinishedUploads[key, default: []].append(fingerprint)
        defer {
            if lastUploads[key] == ended { lastUploads[key] = nil }
            if let index = unfinishedUploads[key]?.firstIndex(of: fingerprint) {
                unfinishedUploads[key]?.remove(at: index)
            }
        }
        // A cancelled caller, as a sign-out's, stops the upload rather than waiting for it.
        return try await withTaskCancellationHandler { try await upload.value } onCancel: { upload.cancel() }
    }

    func forgetUploads(semester: String? = nil) {
        uploads.forget(semester.map(UploadLedger.courses))
    }

    var holdsUnsentCourseUploads: Bool {
        let prefix = UploadLedger.courses("")
        return uploads.holdsFailure(prefix: prefix) || unfinishedUploads.contains { key, fingerprints in
            key.hasPrefix(prefix) && fingerprints.contains { !uploads.accepts(key, fingerprint: $0) }
        }
    }

    static func fingerprint(of request: PushAPI.CourseUploadRequest) -> Int {
        encodedFingerprint(PushAPI.CourseUploadRequest(
            courses: request.courses.sorted { $0.courseNo < $1.courseNo },
            courseOverrides: request.courseOverrides.sorted { $0.courseKey < $1.courseKey }
        ))
    }

    static func fingerprint(of request: PushAPI.AssignmentUploadRequest) -> Int {
        encodedFingerprint(PushAPI.AssignmentUploadRequest(
            assignments: request.assignments.sorted { $0.moodleAssignmentId < $1.moodleAssignmentId }
        ))
    }

    private static func encodedFingerprint(_ value: some Encodable) -> Int {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var hasher = Hasher()
        guard let data = try? encoder.encode(value) else { return Int.random(in: .min ... .max) }
        hasher.combine(data)
        return hasher.finalize()
    }

    func deleteAllCourses(semester: String? = nil) async throws {
        try await apiClient.deleteAllCourses(semester: semester)
    }

    func deleteCourse(courseKey: String) async throws {
        try await apiClient.deleteCourse(courseKey: courseKey)
    }

    func deleteCourse(courseKey: String, madeAt stamp: Date) async throws {
        try await apiClient.deleteCourse(courseKey: courseKey, madeAt: stamp)
    }

    /// A new session or device registration may come to a server without this device's schedule,
    /// so the next list goes up even when unchanged.
    func refreshRegistrationAfterAuth() {
        scheduleSync.forgetAcceptedList()
        if stoppedBySignOut {
            stoppedBySignOut = false
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
            isStarted: isStarted,
            liveActivitiesEnabled: liveActivitiesEnabled,
            notificationAuthStatus: notificationStatus,
            registration: reg,
            resolvedServerURL: PushServerConfig.resolveServerURL(),
            uuid: identity.uuid
        )
    }

    @discardableResult
    func disable() async -> Bool {
        guard isStarted else { return false }
        isStarted = false
        stoppedBySignOut = true
        acceptedMoodleCredentials = nil
        logger.info("disabling push stack")

        #if os(iOS)
        relay.stop()
        #endif
        pendingSyncTask?.cancel()
        await pendingSyncTask?.value
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
        pendingSyncTask?.cancel()
        pendingSyncTask = Task { @MainActor [weak self] in
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

    /// Sends nothing when the list is the one the server last took, as most sync triggers change
    /// nothing in it.
    func syncNow(inputsBuilder: @MainActor () -> ScheduleSyncService.Inputs) async {
        guard await apiClient.hasAuthSession(), isStarted else { return }
        guard isProtectedDataAvailable() else { return }
        scheduleSync.sync(inputs: inputsBuilder(), unlessUnchanged: true)
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

nonisolated struct UploadLedger {
    static let assignments = "assignments"
    static func courses(_ semester: String) -> String { "courses:\(semester)" }

    /// Every fetch, sync and push would send a list the server answered with an error again at
    /// once, each answered the same way, so the same list waits this long from the answer.
    static let refusalPause: TimeInterval = 60

    private var accepted: [String: (fingerprint: Int, at: Date)] = [:]
    private var failed: [String: Int] = [:]
    private var refused: [String: (fingerprint: Int, at: Date)] = [:]
    private var forgetsOfKey: [String: Int] = [:]
    private var forgetsOfAll = 0

    func generation(of key: String) -> (all: Int, key: Int) {
        (forgetsOfAll, forgetsOfKey[key, default: 0])
    }

    func isDue(_ key: String, fingerprint: Int, now: Date) -> Bool {
        PushCoordinator.uploadIsDue(accepted: accepted[key], fingerprint: fingerprint, now: now)
    }

    func isHeldBack(_ key: String, fingerprint: Int, now: Date) -> Bool {
        guard let refusal = refused[key], refusal.fingerprint == fingerprint else { return false }
        return (0..<Self.refusalPause).contains(now.timeIntervalSince(refusal.at))
    }

    mutating func record(_ key: String, fingerprint: Int, at date: Date, startedIn started: (all: Int, key: Int)) {
        guard started == generation(of: key) else { return }
        accepted[key] = (fingerprint, date)
        failed[key] = nil
        refused[key] = nil
    }

    mutating func recordRefusal(_ key: String, fingerprint: Int, at date: Date, startedIn started: (all: Int, key: Int)) {
        guard started == generation(of: key) else { return }
        refused[key] = (fingerprint, date)
    }

    mutating func recordFailure(_ key: String, fingerprint: Int, startedIn started: (all: Int, key: Int)) {
        guard started == generation(of: key) else { return }
        failed[key] = fingerprint
    }

    mutating func forgetFailure(_ key: String) {
        failed[key] = nil
    }

    func accepts(_ key: String, fingerprint: Int) -> Bool {
        accepted[key]?.fingerprint == fingerprint
    }

    /// A failed list the server took earlier, as an unchanged resend that failed, is not unsent.
    func holdsFailure(prefix: String) -> Bool {
        failed.contains { $0.key.hasPrefix(prefix) && !accepts($0.key, fingerprint: $0.value) }
    }

    mutating func forget(_ key: String?) {
        if let key {
            forgetsOfKey[key, default: 0] &+= 1
            accepted[key] = nil
            failed[key] = nil
            refused[key] = nil
        } else {
            forgetsOfAll &+= 1
            accepted = [:]
            failed = [:]
            refused = [:]
        }
    }
}
