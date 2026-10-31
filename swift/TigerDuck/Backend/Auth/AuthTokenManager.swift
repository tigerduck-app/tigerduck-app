import Foundation
import os

actor AuthTokenManager {
    // Internal for `StoredTokenRefresher` and `DepartingSessionKeeper`, which run isolated to this actor.
    var pair: AuthTokenPair
    var signIns = SignInCount()
    var refreshes = Refreshes()
    var handlers = Handlers()
    let signOutsStarting = OSAllocatedUnfairLock(initialState: 0)
    private var turns = SignInTurns()
    private let requests: AuthRequests
    private let departingSessions: DepartingSessionKeeper
    private let refresher: StoredTokenRefresher

    /// One sign-in at a time; the ones waiting resume in turn.
    private struct SignInTurns {
        var isSigningIn = false
        var waiting: [CheckedContinuation<Void, Never>] = []
    }

    struct Refreshes {
        var task: Task<String?, Never>?
        /// Keyed by the refresh token each sent: a refresh of a pair a sign-in replaced can end after the
        /// next pair's, and a sign-out takes only the one of the token it ends.
        var late: [String: (ticket: AccountSession.Ticket, accessToken: String?, refreshToken: String?, mayResend: Bool)] = [:]
    }

    struct Handlers {
        var refreshFailed: (() async -> Bool)?
        var rejected: ((_ refused: String) async -> Bool)?
        var noSession: (() async -> Void)?
    }

    func setRefreshFailedHandler(_ handler: @escaping () async -> Bool) {
        handlers.refreshFailed = handler
    }

    /// Signs in again after the backend ended the session a request carried.
    func setSignInAgainHandler(_ handler: @escaping (_ refused: String) async -> Bool) {
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

    /// A sign-out's account for its unregister: the token, the backend that issued it and the
    /// session it kept there, which the unregister forgets once it lands.
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
        self.pair = AuthTokenPair(tokens: tokens)
    }

    /// The bearer token for `BackendClient`, and its one recovery after a 401.
    nonisolated var backendAuth: BackendAuth {
        BackendAuth(
            header: { [weak self] in await self?.authorizationHeader() },
            recover: { [weak self] refused, code in await self?.recover(fromRejectionOf: refused, code: code) ?? false }
        )
    }

    /// The codes of a session the backend ended; a refresh would only spend a use of its token.
    static let endedSessionCodes: Set<String> = ["session_revoked", "session_user_mismatch"]

    /// After a 401 for `refused`: true once another access token is ready for one replay. An
    /// ended session signs in again; any other refusal takes a refresh, which the budget bounds.
    func recover(fromRejectionOf refused: String, code: String?) async -> Bool {
        guard Self.departing == nil, pair.refreshToken != nil else { return false }
        if let code, Self.endedSessionCodes.contains(code) {
            guard let onRejected = handlers.rejected, await onRejected(refused) else { return false }
            return pair.accessToken.map { $0 != refused } ?? false
        }
        if let stored = pair.accessToken, stored != refused { return true }
        pair.expiresAt = .distantPast
        guard let token = await validAccessToken() else { return false }
        return token != refused
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
        guard let token = await validAccessToken() else { return nil }
        return "Bearer \(token)"
    }

    struct LoginResult: Sendable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        let userId: String
        let deviceId: String
    }

    /// `refused` is the access token a request was turned away with. A sign-in for it that finds
    /// another pair stored once its turn comes sends nothing and returns nil: the request was
    /// refused for that pair's sign-in or refresh, and the caller retries with it.
    @discardableResult
    func login(
        studentId: String,
        moodleToken: String?,
        moodlePrivateToken: String?,
        platform: String,
        replacing refused: String? = nil
    ) async throws -> LoginResult? {
        // One at a time: a sign-in ends the device's older sessions, so the pair stored last has to be
        // the one the backend issued last (https://github.com/tigerduck-app/tigerduck-backend/issues/48).
        let ticket = signIns.ticket
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
        guard signIns.isCurrent(ticket) else { throw CancellationError() }
        let result = try await requests.send(login: request)
        guard signIns.isCurrent(ticket) else { throw CancellationError() }
        pair.store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
        // A refresh still out is the replaced pair's, so neither a caller nor a sign-out waits on it.
        refreshes.task = nil
        // A session kept on another backend still has the device there; the launch retry sends it.
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
        signIns.moveOn()
        pair.clear()
    }

    /// Holds back the session's tokens until `endSession(on:)` has ended it, and returns the backend in
    /// use for its unregister. It runs at once on the caller's thread, so the tokens are held before
    /// an API endpoint change can store its new endpoint.
    nonisolated func beginSignOut() -> URL {
        signOutsStarting.withLock { $0 += 1 }
        return requests.baseURL()
    }

    func endSession(on backend: URL? = nil) async -> DepartingAccount {
        let baseURL = backend ?? requests.baseURL()
        let access = pair.accessToken, refresh = pair.refreshToken, expiry = pair.expiresAt
        let refreshOut = refreshes.task, ticket = signIns.ticket, uses = pair.budget.uses
        logout()
        signOutsStarting.withLock { $0 = max($0 - 1, 0) }
        guard let refresh else { return DepartingAccount(accessToken: nil, baseURL: baseURL) }
        let departing = DepartingSession(
            refreshToken: refresh, uses: uses + (refreshOut == nil ? 0 : 1), baseURL: baseURL, id: UUID().uuidString
        )
        departingSessions.list.add(departing)
        let token = await departingSessions.signOutToken(
            for: departing, access: access, expiry: expiry, refreshOut: refreshOut, ticket: ticket, uses: uses, of: self
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

    /// Whether a launch sends the session kept on `kept`. While signed in, one on the backend in use
    /// went to the new account with the device. One on a cleartext backend goes out only while that
    /// backend is in use: on another network its private address may name another host.
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
