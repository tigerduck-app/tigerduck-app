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

/// What a full sync came to, which a sync trigger push reports to the system.
nonisolated enum FullSyncOutcome: Equatable, Sendable {
    case synced
    case failed
    /// It did not reach the server: sync off, signed out, locked, turned away or cancelled.
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

/// Owns the push-server lifecycle: registering for remote notifications,
/// handing APNs and push-to-start (`PushTokenRelay`) tokens to
/// `PushRegistrationService`, and debouncing sync bursts into one POST.
///
/// AppState holds a single instance. `enable()` brings the stack up
/// idempotently at every launch past onboarding; `disable()` at sign-out is
/// the only way down. No stored flag gates either: a user can turn off a
/// delivery channel (bulletins, operator pushes), never the registration.
@MainActor
final class PushCoordinator {
    private let identity: PushIdentity
    private let apiClient: PushAPIClient
    /// Exposed `internal` so AppState can call user-preference helpers
    /// (e.g. `updateServerPushOptOut`) without re-plumbing them through
    /// every layer. The actor still owns its own state — callers only see
    /// its async methods.
    let registration: PushRegistrationService
    #if os(iOS)
    private let relay: PushTokenRelay
    #endif
    let scheduleSync: ScheduleSyncService

    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Coord")

    private var isStarted = false
    /// Set by ``disable()``, which only a sign-out calls: its unregister dropped the APNs tokens,
    /// and nothing but a launch or this flag starts the stack again.
    private var stoppedBySignOut = false
    private var pendingSyncTask: Task<Void, Never>?

    init(
        identity: PushIdentity = .loadOrCreate(),
        apiClient: PushAPIClient? = nil,
        authTokenManager: AuthTokenManager? = nil
    ) {
        self.identity = identity
        // The auth header comes from `authTokenManager`. Without one (unit
        // tests, for example) the client sends no `Authorization` header.
        let resolvedClient: PushAPIClient
        if let apiClient {
            resolvedClient = apiClient
        } else if let atm = authTokenManager {
            resolvedClient = PushAPIClient(
                authHeaderProvider: { await atm.authorizationHeader() }
            )
        } else {
            // Pass no URL: the default provider re-resolves `PushServerConfig`
            // on every request, so a runtime endpoint override takes effect
            // without an app relaunch.
            resolvedClient = PushAPIClient()
        }
        self.apiClient = resolvedClient
        self.registration = PushRegistrationService(
            identity: identity,
            apiClient: resolvedClient,
            // Evaluated here in `PushCoordinator`'s `@MainActor` init so the
            // `@MainActor` `resolvedForBuild` (reads `UIDevice.current`) is
            // reached from the main actor.
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

    // MARK: - Lifecycle

    /// Called through `AppState.bindPushDelegate`: by the launch work once the launch is built, and
    /// again in `.onAppear`. A token that arrives before it waits in the delegate.
    func bindTokenForwarding(_ appDelegate: some PushTokenSource) {
        appDelegate.forwardToken = { [weak self] data in
            guard let self else { return }
            Task { await self.registration.update(deviceToken: data) }
        }
        appDelegate.forwardError = { [weak self] error in
            guard let self else { return }
            Task { await self.registration.registrationFailed(error) }
        }
    }

    /// Enable the full push stack. Safe to call repeatedly.
    ///
    /// - Parameter requestPermission: `true` also shows the iOS permission
    ///   prompt, as visible feedback for an explicit "turn on" tap. Pass
    ///   `false` for the silent auto-enable at every launch: it only calls
    ///   `registerForRemoteNotifications`, a no-op until the user grants
    ///   permission elsewhere (usually onboarding). Auto-enable must not
    ///   prompt, or the system alert would land on top of OnboardingView.
    func enable(requestPermission: Bool = false) {
        // Only the relay start is one-time. Launch auto-enable sets `isStarted`
        // first, so a later `requestPermission: true` call must still prompt
        // and register, or the device gets no APNs token or server registration.
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

    /// How often an unchanged Moodle token goes to the server again. The server checks each
    /// update against Moodle, and a resend is what revives a sync job it disabled.
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

    /// Called on every return to the app. Sends a changed token at once and an unchanged one
    /// hourly; a token the server did not accept goes again on the next return.
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

    /// How often an unchanged course or assignment list goes to the server again. The backend
    /// upserts every row of an upload, but an unchanged one moves no revision, so skipping it
    /// loses only the server's bookkeeping: `last_seen_at`, a log row, its sync push-back.
    nonisolated static let unchangedUploadInterval: TimeInterval = 6 * 3600

    /// The lists the server accepted. In memory, so a relaunch sends again; sign-out, a term
    /// reset and a sync switch coming back on forget them.
    private var uploads = UploadLedger()
    /// The last upload of each list. The next one waits for it, so its check sees what that one
    /// left: an edit undone while its upload was out still goes up after it.
    private var lastUploads: [String: Task<Void, Never>] = [:]

    nonisolated static func uploadIsDue(accepted: (fingerprint: Int, at: Date)?, fingerprint: Int, now: Date) -> Bool {
        guard let accepted, accepted.fingerprint == fingerprint else { return true }
        let age = now.timeIntervalSince(accepted.at)
        return age >= unchangedUploadInterval || age < 0
    }

    /// Uploads a term's course list unless the server accepted the same one within
    /// `unchangedUploadInterval`. `forceKeys` and `resend` always send. Returns whether it sent.
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

    /// Uploads the assignment list unless the server accepted the same one within
    /// `unchangedUploadInterval`. Returns whether it sent.
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

    /// Runs `send` for list `key` once the list's previous upload has ended, unless `always` is
    /// false and the ledger holds `fingerprint` as accepted within `unchangedUploadInterval`.
    /// `isCurrent` is checked after that wait, which can span a sign-out: the request would
    /// carry the departing account's list on the next account's token.
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
            guard let self, isCurrent() else { return false }
            let now = Date()
            guard always || self.uploads.isDue(key, fingerprint: fingerprint, now: now) else { return false }
            let started = self.uploads.generation(of: key)
            try await send()
            self.uploads.record(key, fingerprint: fingerprint, at: now, startedIn: started)
            return true
        }
        let ended = Task<Void, Never> { _ = try? await upload.value }
        lastUploads[key] = ended
        defer { if lastUploads[key] == ended { lastUploads[key] = nil } }
        return try await upload.value
    }

    /// Forgets the accepted course lists of `semester`, or of every term and the assignment list
    /// when nil, so the next upload goes whatever it holds.
    func forgetUploads(semester: String? = nil) {
        uploads.forget(semester.map(UploadLedger.courses))
    }

    /// The same list in any order gives the same fingerprint. Force keys are left out: a request
    /// with any always goes.
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
        // A list that does not encode cannot be told apart from the last one, so it always goes.
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

    /// Re-attempt device registration after a sign-in. The launch-time
    /// registration runs before the v3 JWT exists and 401s; calling this once
    /// a Bearer is available gives it a fresh attempt — and resets the give-up
    /// counter — instead of waiting on exponential backoff (or never retrying
    /// if it already exhausted its attempts while unauthenticated). After a sign-out in the same
    /// run it starts the stack again first, for the tokens that sign-out's unregister dropped.
    func refreshRegistrationAfterAuth() {
        if stoppedBySignOut {
            stoppedBySignOut = false
            enable()
        }
        Task { await registration.registerAgain() }
    }

    func registerAgainIfGaveUp() {
        Task { await registration.registerAgainIfGaveUp() }
    }

    /// Returns the latest diagnostic snapshot for the settings view.
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

    /// Disable and inform the server. Safe to call repeatedly.
    func disable() async {
        guard isStarted else { return }
        isStarted = false
        stoppedBySignOut = true
        acceptedMoodleCredentials = nil
        logger.info("disabling push stack")

        #if os(iOS)
        relay.stop()
        #endif
        pendingSyncTask?.cancel()
        // Let a running sync finish before unregistering so a stale POST cannot
        // recreate deleted state. `pendingSyncTask` covers only the debounce
        // and builder; the POST runs in `ScheduleSyncService.inflight`.
        await pendingSyncTask?.value
        await scheduleSync.awaitInflight()
        await registration.unregister()
    }

    #if os(iOS)
    func registerLiveActivityUpdateToken(
        _ registrationPayload: LiveActivityUpdateTokenRegistration
    ) async {
        await registration.registerLiveActivityUpdateToken(registrationPayload)
    }
    #endif

    // MARK: - Sync driver

    /// Schedules a debounced sync. Multiple rapid callers coalesce into one
    /// POST. Drops the sync when the app is backgrounded or there is no
    /// session to authenticate `/schedule/sync` with.
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
            // `/schedule/sync` needs auth and would only 401 without a usable
            // token. Not `isLoggedIn`: that only means a refresh token exists,
            // and it stays true for a stale one that fails to refresh.
            guard await self?.apiClient.hasAuthSession() == true else { return }
            let inputs = inputsBuilder()
            self?.scheduleSync.sync(inputs: inputs)
        }
    }

    // MARK: - Build-time env sanity

    /// Crashes Debug builds at launch when the resolved server URL does not
    /// match the APNs environment baked into the binary (or each other).
    /// Empty in Release builds: `assert` is stripped under `-O`, but working out
    /// its conditions would still read the Keychain twice before the first frame.
    ///
    /// Guards against the regression where someone flips `PushAPNsEnv` or
    /// `AppConstants.productionPushServerURL` without flipping the other,
    /// or seeds a stale UserDefaults override pointing the wrong way.
    nonisolated static func assertEnvConsistency() {
        #if DEBUG
        let resolved = PushServerConfig.resolveServerURL()
        let host = resolved.host?.lowercased() ?? ""
        // A user-set endpoint skips the host check: self-hosted backends are
        // valid, and a launch crash would leave no UI to clear the Keychain
        // entry. A Debug build aimed at prod then fails at push registration.
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

/// The fingerprint of each list the server last accepted, by `courses(_:)` or `assignments`.
nonisolated struct UploadLedger {
    static let assignments = "assignments"
    static func courses(_ semester: String) -> String { "courses:\(semester)" }

    private var accepted: [String: (fingerprint: Int, at: Date)] = [:]
    private var forgetsOfKey: [String: Int] = [:]
    private var forgetsOfAll = 0

    /// Moved by a forget of `key` or of every list. An upload in flight across one records
    /// nothing: it may have reached the server before what the forget answers, a term reset, so
    /// its list is not on the server now.
    func generation(of key: String) -> (all: Int, key: Int) {
        (forgetsOfAll, forgetsOfKey[key, default: 0])
    }

    func isDue(_ key: String, fingerprint: Int, now: Date) -> Bool {
        PushCoordinator.uploadIsDue(accepted: accepted[key], fingerprint: fingerprint, now: now)
    }

    mutating func record(_ key: String, fingerprint: Int, at date: Date, startedIn started: (all: Int, key: Int)) {
        guard started == generation(of: key) else { return }
        accepted[key] = (fingerprint, date)
    }

    /// `key` nil forgets every list.
    mutating func forget(_ key: String?) {
        if let key {
            forgetsOfKey[key, default: 0] &+= 1
            accepted[key] = nil
        } else {
            forgetsOfAll &+= 1
            accepted = [:]
        }
    }
}
