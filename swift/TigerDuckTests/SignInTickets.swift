import Foundation
@testable import TigerDuck

/// The sign-ins of `testSignIn`, which no test ends.
let testSignIns = SignInSeries()

/// A sign-in no test ends, for writes and sends that are meant to land.
let testSignIn = testSignIns.currentSignIn

/// A sign-in that ended before the test began.
let endedTestSignIn = TestSignIn.ended().signIn

/// A sign-in a test ends from any actor, as its account signing out.
final class TestSignIn: Sendable {
    private let series = SignInSeries()
    let signIn: SignIn

    init() {
        signIn = series.currentSignIn
    }

    static func ended() -> TestSignIn {
        let ended = TestSignIn()
        ended.signOut()
        return ended
    }

    func signOut() { series.end() }
}

extension BackendAuth {
    /// A header of the current sign-in of `signIns`, as the token manager's names the sign-in of its token.
    static func signedIn(
        in signIns: SignInSeries = testSignIns, _ header: @escaping @Sendable () async -> String?
    ) -> BackendAuth {
        BackendAuth(header: { await header().map { ($0, signIns.currentSignIn) } }, recover: { _, _, _ in false })
    }
}

extension PushAPIClient {
    convenience init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        session: URLSession? = nil,
        authHeaderProvider: @escaping @Sendable () async -> String?,
        versionGate: APIVersionGate? = nil,
        signIns: SignInSeries = testSignIns
    ) {
        self.init(baseURLProvider: baseURLProvider, session: session, auth: .signedIn(in: signIns, authHeaderProvider),
                  versionGate: versionGate)
    }
}

extension BulletinAPIClient {
    convenience init(
        baseURLProvider: @escaping @Sendable () -> URL,
        session: URLSession?,
        authHeaderProvider: @escaping @Sendable () async -> String?
    ) {
        self.init(baseURLProvider: baseURLProvider, session: session, auth: .signedIn(authHeaderProvider), for: testSignIn)
    }
}

extension SyncOutbox {
    func enqueue(_ op: SyncOp) { enqueue(op, for: testSignIn) }

    @discardableResult
    func drain(
        holding isHeld: @Sendable (SyncOp) -> Bool = { _ in false },
        execute: @Sendable (SyncOp) async throws -> Void
    ) async -> Bool {
        await drain(for: testSignIn, holding: isHeld) { op, _ in try await execute(op) }
    }
}

extension CloudSyncCoordinator {
    @discardableResult
    func enqueueCourseColorOverride(moodleId: String, semester: String, colorHex: String) -> Task<Void, Never>? {
        enqueueCourseColorOverride(moodleId: moodleId, semester: semester, colorHex: colorHex, for: testSignIn)
    }

    @discardableResult
    func enqueueCourseNameOverride(
        moodleId: String, semester: String, customName: String, locale: String?
    ) -> Task<Void, Never>? {
        enqueueCourseNameOverride(moodleId: moodleId, semester: semester, customName: customName, locale: locale, for: testSignIn)
    }

    func enqueueAssignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String) async {
        await enqueueAssignmentOverride(
            moodleCourseId: moodleCourseId, moodleAssignmentId: moodleAssignmentId, localStatus: localStatus, for: testSignIn
        )
    }

    func enqueueCourseIgnore(semester: String, courseNo: String, moodleId: String, moodleCourseId: Int?, ignore: Bool?) async {
        await enqueueCourseIgnore(
            semester: semester, courseNo: courseNo, moodleId: moodleId, moodleCourseId: moodleCourseId, ignore: ignore,
            for: testSignIn
        )
    }

    func enqueueCourseDelete(semester: String, courseNo: String, at stamp: Date = Date()) async {
        await enqueueCourseDelete(semester: semester, courseNo: courseNo, at: stamp, for: testSignIn)
    }

    func deleteCourse(semester: String, courseNo: String, at stamp: Date = Date()) async {
        await deleteCourse(semester: semester, courseNo: courseNo, at: stamp, for: testSignIn)
    }

    @discardableResult
    func addCourse(semester: String, courseNo: String) -> Task<Void, Never> {
        addCourse(semester: semester, courseNo: courseNo, for: testSignIn)
    }
}

extension PushAPIClient {
    func fetchRevision() async throws -> Int { try await fetchRevision(for: testSignIn) }

    func fetchChanges(sinceRevision: Int) async throws -> PushAPI.SyncChangesPage {
        try await fetchChanges(sinceRevision: sinceRevision, for: testSignIn)
    }
}

extension PushCoordinator {
    convenience init(
        identity: PushIdentity = .loadOrCreate(),
        apiClient: PushAPIClient? = nil,
        authTokenManager: AuthTokenManager? = nil,
        ledger: SendLedger? = nil,
        isProtectedDataAvailable: (@MainActor () -> Bool)? = nil
    ) {
        self.init(
            identity: identity, apiClient: apiClient, authTokenManager: authTokenManager, ledger: ledger,
            isProtectedDataAvailable: isProtectedDataAvailable, signIns: testSignIns
        )
    }
}

extension PushRegistrationService {
    init(
        identity: PushIdentity,
        apiClient: PushAPIClient,
        deviceClass: String,
        debounceSleep: @escaping @Sendable (Duration) async -> Void,
        retrySleep: @escaping @Sendable (Duration) async -> Void
    ) {
        self.init(
            identity: identity, apiClient: apiClient, signIns: testSignIns, deviceClass: deviceClass,
            debounceSleep: debounceSleep, retrySleep: retrySleep
        )
    }
}

extension ScheduleSyncService {
    func sync(inputs: Inputs) { sync(inputs: inputs, for: testSignIn) }
}
