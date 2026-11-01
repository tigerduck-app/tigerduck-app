import Foundation
import os

actor AuthTokenManager {
    var pair: AuthTokenPair
    var refreshes = Refreshes()
    var handlers = Handlers()
    let signOutsStarting = OSAllocatedUnfairLock(initialState: 0)
    private var turns = SignInTurns()
    private let requests: AuthRequests
    private let departingSessions: DepartingSessionKeeper
    private let refresher: StoredTokenRefresher

    private struct SignInTurns {
        var isSigningIn = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    struct Refreshes {
        var task: Task<String?, Never>?
        var late: [String: (signIn: SignIn, accessToken: String?, refreshToken: String?, mayResend: Bool)] = [:]
    }

    struct Handlers {
        var refreshFailed: ((SignIn) async -> Bool)?
        var rejected: ((_ refused: String, _ signIn: SignIn) async -> Bool)?
        var noSession: (() async -> Void)?
    }

    func setRefreshFailedHandler(_ handler: @escaping (SignIn) async -> Bool) {
        handlers.refreshFailed = handler
    }

    /// Signs in again after the backend ended the session a request carried.
    func setSignInAgainHandler(_ handler: @escaping (_ refused: String, _ signIn: SignIn) async -> Bool) {
        handlers.rejected = handler
    }

    func setNoSessionHandler(_ handler: @escaping () async -> Void) {
        handlers.noSession = handler
    }

    static let accessTokenKey = "v3_access_token"
    static let refreshTokenKey = "v3_refresh_token"
    static let expiresAtKey = "v3_token_expires_at"
    static let refreshTokenUsesKey = "v3_refresh_token_uses"
    static let departingSessionKey = "v3_departing_session"

    static let refreshTimeout: TimeInterval = 20

    @TaskLocal static var departing: DepartingAccount?

    struct DepartingAccount: Sendable {
        let accessToken: String?
        var baseURL: URL?
        var sessionID: String?
    }

    static let signOutCallsWindow: TimeInterval = 120

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        deviceUUID: String,
        session: URLSession = .shared,
        tokens: TokenStore = .keychain,
        storedFor signIn: SignIn = SignInSeries().currentSignIn,
        refreshTimeout: TimeInterval = AuthTokenManager.refreshTimeout,
        beginBackgroundTask: @escaping @Sendable () async -> @Sendable () async -> Void
            = AuthTokenManager.beginRefreshBackgroundTask
    ) {
        let requests = AuthRequests(
            baseURL: baseURLProvider, deviceUUID: deviceUUID,
            backend: BackendClient(baseURL: baseURLProvider, session: session), refreshTimeout: refreshTimeout
        )
        self.requests = requests
        self.departingSessions = DepartingSessionKeeper(list: DepartingSessionList(tokens: tokens), requests: requests)
        self.refresher = StoredTokenRefresher(requests: requests, beginBackgroundTask: beginBackgroundTask)
        self.pair = AuthTokenPair(tokens: tokens, signIn: signIn)
    }

    nonisolated var backendAuth: BackendAuth {
        BackendAuth(
            header: { [weak self] in await self?.authorizationHeaderOfSignIn() },
            recover: { [weak self] in await self?.recover(fromRejectionOf: $0, code: $1, signIn: $2) ?? false }
        )
    }

    static let endedSessionCodes: Set<String> = ["session_revoked", "session_user_mismatch"]

    func recover(fromRejectionOf refused: String, code: String?, signIn: SignIn) async -> Bool {
        guard Self.departing == nil, pair.refreshToken != nil, pair.holds(signIn) else { return false }
        if let code, Self.endedSessionCodes.contains(code) {
            guard let onRejected = handlers.rejected, await onRejected(refused, signIn) else { return false }
            return (pair.accessToken.map { $0 != refused } ?? false) && pair.holds(signIn)
        }
        if let stored = pair.accessToken, stored != refused { return true }
        pair.expiresAt = .distantPast
        guard let token = await validAccessToken() else { return false }
        return token != refused && pair.holds(signIn)
    }

    var isLoggedIn: Bool { pair.refreshToken != nil }

    var storedAccessToken: String? { pair.accessToken }

    var signInsWaiting: Int { turns.waiting.count }

    func validAccessToken() async -> String? {
        if let departing = Self.departing { return departing.accessToken }
        if signOutsStarting.withLock({ $0 > 0 }) { return nil }
        if pair.refreshToken == nil, let onNoSession = handlers.noSession { await onNoSession() }
        guard pair.refreshToken != nil else { return nil }
        if let token = pair.accessToken, Date.now < pair.expiresAt.addingTimeInterval(-30) {
            return token
        }
        if let inFlight = refreshes.task {
            return await inFlight.value
        }
        let task = Task { await refresher.refresh(of: self) }
        refreshes.task = task
        let token = await task.value
        if refreshes.task == task { refreshes.task = nil }
        return token
    }

    func authorizationHeader() async -> String? {
        await authorizationHeaderOfSignIn()?.value
    }

    func authorizationHeaderOfSignIn() async -> (value: String, signIn: SignIn?)? {
        if let departing = Self.departing { return departing.accessToken.map { ("Bearer \($0)", nil) } }
        guard let token = await validAccessToken(), token == pair.accessToken, let signIn = pair.signIn,
              pair.holds(signIn) else { return nil }
        return ("Bearer \(token)", signIn)
    }

    struct LoginResult: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let userId: String
        let deviceId: String
    }

    /// `refused` is the access token a request was turned away with. A sign-in for it that finds
    /// another pair stored once its turn comes sends nothing and returns nil, and the caller retries
    /// with that pair.
    @discardableResult
    func login(
        studentId: String,
        moodleToken: String?,
        moodlePrivateToken: String?,
        platform: String,
        for signIn: SignIn,
        replacing refused: String? = nil
    ) async throws -> LoginResult? {
        if turns.isSigningIn {
            await withCheckedContinuation { turns.waiting.append($0) }
        } else {
            turns.isSigningIn = true
        }
        defer {
            if turns.waiting.isEmpty { turns.isSigningIn = false } else { turns.waiting.removeFirst().resume() }
        }
        if let refused, let stored = pair.accessToken, stored != refused { return nil }
        let baseURL = requests.baseURL()
        let request = try requests.login(
            studentId: studentId, moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken,
            platform: platform, to: baseURL
        )
        guard signIn.isCurrent else { throw CancellationError() }
        let result = try await requests.send(login: request)
        guard signIn.isCurrent else { throw CancellationError() }
        pair.store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in, for: signIn)
        refreshes.task = nil
        departingSessions.list.forgetAll(on: baseURL)
        return LoginResult(
            accessToken: result.access_token,
            refreshToken: result.refresh_token,
            expiresIn: result.expires_in,
            userId: result.user.id,
            deviceId: result.device_id
        )
    }

    func logout() {
        pair.clear()
    }

    /// Holds back the session's tokens until `endSession(on:)` has ended it, and returns the backend in
    /// use for its unregister.
    nonisolated func beginSignOut() -> URL {
        signOutsStarting.withLock { $0 += 1 }
        return requests.baseURL()
    }

    func endSession(on backend: URL? = nil) async -> DepartingAccount {
        let baseURL = backend ?? requests.baseURL()
        let access = pair.accessToken, refresh = pair.refreshToken, expiry = pair.expiresAt
        let refreshOut = refreshes.task, signIn = pair.signIn, uses = pair.budget.uses
        logout()
        signOutsStarting.withLock { $0 = max($0 - 1, 0) }
        guard let refresh else { return DepartingAccount(accessToken: nil, baseURL: baseURL) }
        let departing = DepartingSession(
            refreshToken: refresh, uses: uses + (refreshOut == nil ? 0 : 1), baseURL: baseURL, id: UUID().uuidString
        )
        departingSessions.list.add(departing)
        let token = await departingSessions.signOutToken(
            for: departing, access: access, expiry: expiry, refreshOut: refreshOut, signIn: signIn, uses: uses, of: self
        )
        return DepartingAccount(accessToken: token, baseURL: baseURL, sessionID: departing.id)
    }

    nonisolated var hasDepartingSession: Bool { departingSessions.hasSession }

    nonisolated var departingSessionBackends: [URL] { departingSessions.backends }

    func departingAccessToken() async -> String? {
        guard let session = departingSessions.list.load().first else { return nil }
        return await departingSessions.accessToken(for: session, of: self)
    }

    /// One server's base URL can be spelled with or without a trailing slash, with its scheme and
    /// host in either case, and for `/v3` or `/v4`.
    nonisolated static func isSameBackend(_ one: URL, _ other: URL) -> Bool {
        let server = { (url: URL) -> [String?] in
            let url = BackendClient.apiBase(url)
            let path = url.standardized.path(percentEncoded: true)
            return [
                url.scheme?.lowercased(), url.host(percentEncoded: true)?.lowercased(), url.port.map(String.init),
                String(path.reversed().drop { $0 == "/" }.reversed()), url.query(percentEncoded: true),
            ]
        }
        return server(one) == server(other)
    }

    nonisolated static func retriesKeptSession(on kept: URL, signedIn: Bool, backend: URL) -> Bool {
        let inUse = isSameBackend(kept, backend)
        return (!signedIn || !inUse) && (kept.scheme?.lowercased() != "http" || inUse)
    }

    func retryDepartingUnregister(_ unregister: @MainActor @Sendable (_ backend: URL) async -> Bool) async {
        await departingSessions.retryUnregister(of: self, unregister)
    }

    func unregisterDeparting(as account: DepartingAccount, _ unregister: @MainActor @Sendable () async -> Bool) async {
        let session = account.sessionID.flatMap { id in departingSessions.list.load().first { $0.id == id } }
        await departingSessions.unregister(session, as: account, of: self, unregister)
    }

    nonisolated static func beginRefreshBackgroundTask() async -> @Sendable () async -> Void {
        await beginBackgroundTask(named: "Backend token refresh")
    }

    nonisolated static func beginBackgroundTask(named name: String) async -> @Sendable () async -> Void {
        await AppBackgroundTask.begin(named: name)
    }

    enum AuthError: Error {
        case loginFailed
    }
}
