import Foundation
import os
#if os(iOS)
import UIKit
#endif

actor AuthTokenManager {
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast
    private var refreshTask: Task<String?, Never>?
    private var isSigningIn = false
    private var waitingSignIns: [CheckedContinuation<Void, Never>] = []
    private var signIns = SignInCount()
    /// Keyed by the refresh token each sent: a refresh of a pair a sign-in replaced can end after the
    /// next pair's, and a sign-out takes only the one of the token it ends.
    private var lateRefreshes: [String: (ticket: AccountSession.Ticket, accessToken: String?, refreshToken: String?, mayResend: Bool)] = [:]
    private var budget = RefreshTokenUseBudget()
    private var refreshTokenIsStored = true

    private let baseURLProvider: @Sendable () -> URL
    private let deviceUUID: String
    private let backend: BackendClient
    private let refreshRequestTimeout: TimeInterval
    private let tokens: TokenStore
    private let departingSessions: DepartingSessionList
    private let beginBackgroundTask: @Sendable () async -> @Sendable () async -> Void
    private var onRefreshFailed: (() async -> Bool)?
    private var onRejected: ((_ refused: String) async -> Bool)?
    private var onNoSession: (() async -> Void)?

    func setRefreshFailedHandler(_ handler: @escaping () async -> Bool) {
        onRefreshFailed = handler
    }

    /// Signs in again after the backend ended the session a request carried.
    func setSignInAgainHandler(_ handler: @escaping (_ refused: String) async -> Bool) {
        onRejected = handler
    }

    func setNoSessionHandler(_ handler: @escaping () async -> Void) {
        onNoSession = handler
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

    private let signOutsStarting = OSAllocatedUnfairLock(initialState: 0)

    static let signOutCallsWindow: TimeInterval = 120

    nonisolated struct TokenStore: Sendable {
        let load: @Sendable (_ key: String) -> String?
        let save: @Sendable (_ key: String, _ value: String) -> Void
        let delete: @Sendable (_ key: String) -> Void
        var confirmedSave: (@Sendable (_ key: String, _ value: String) -> Bool)?
        var confirmedDelete: (@Sendable (_ key: String) -> Bool)?

        static let keychain = TokenStore(
            load: { KeychainManager.loadString(key: $0) },
            save: { KeychainManager.saveString(key: $0, value: $1) },
            delete: { KeychainManager.delete(key: $0) },
            confirmedSave: { KeychainManager.saveStringReportingSuccess(key: $0, value: $1) },
            confirmedDelete: { KeychainManager.deleteReportingSuccess(key: $0) }
        )

        func saveConfirmed(_ key: String, _ value: String) -> Bool {
            if let confirmedSave { return confirmedSave(key, value) }
            save(key, value)
            return true
        }

        func deleteConfirmed(_ key: String) -> Bool {
            if let confirmedDelete { return confirmedDelete(key) }
            delete(key)
            return true
        }
    }

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        deviceUUID: String,
        session: URLSession = .shared,
        tokens: TokenStore = .keychain,
        refreshTimeout: TimeInterval = AuthTokenManager.refreshTimeout,
        beginBackgroundTask: @escaping @Sendable () async -> @Sendable () async -> Void
            = AuthTokenManager.beginRefreshBackgroundTask
    ) {
        self.baseURLProvider = baseURLProvider
        self.deviceUUID = deviceUUID
        self.backend = BackendClient(baseURL: baseURLProvider, session: session)
        self.refreshRequestTimeout = refreshTimeout
        self.tokens = tokens
        self.departingSessions = DepartingSessionList(tokens: tokens)
        self.beginBackgroundTask = beginBackgroundTask
        self.accessToken = tokens.load(Self.accessTokenKey)
        self.refreshToken = tokens.load(Self.refreshTokenKey)
        if let raw = tokens.load(Self.expiresAtKey),
           let interval = TimeInterval(raw) {
            self.expiresAt = Date(timeIntervalSince1970: interval)
        }
        self.budget = RefreshTokenUseBudget(stored: tokens.load(Self.refreshTokenUsesKey))
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
        guard Self.departing == nil, refreshToken != nil else { return false }
        if let code, Self.endedSessionCodes.contains(code) {
            guard let onRejected, await onRejected(refused) else { return false }
            return accessToken.map { $0 != refused } ?? false
        }
        if let stored = accessToken, stored != refused { return true }
        expiresAt = .distantPast
        guard let token = await validAccessToken() else { return false }
        return token != refused
    }

    var isLoggedIn: Bool { refreshToken != nil }

    var storedAccessToken: String? { accessToken }

    var signInsWaiting: Int { waitingSignIns.count }

    func validAccessToken() async -> String? {
        if let departing = Self.departing { return departing.accessToken }
        if signOutsStarting.withLock({ $0 > 0 }) { return nil }
        if refreshToken == nil, let onNoSession { await onNoSession() }
        guard refreshToken != nil else { return nil }
        if let token = accessToken, Date.now < expiresAt.addingTimeInterval(-30) {
            return token
        }
        if let inFlight = refreshTask {
            return await inFlight.value
        }
        let task = Task { await refresh() }
        refreshTask = task
        let token = await task.value
        if refreshTask == task { refreshTask = nil }
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
        if isSigningIn {
            await withCheckedContinuation { waitingSignIns.append($0) }
        } else {
            isSigningIn = true
        }
        defer {
            if waitingSignIns.isEmpty { isSigningIn = false } else { waitingSignIns.removeFirst().resume() }
        }
        if let refused, let stored = accessToken, stored != refused { return nil }
        return try await sendLogin(
            studentId: studentId, moodleToken: moodleToken, moodlePrivateToken: moodlePrivateToken,
            platform: platform, ticket: ticket
        )
    }

    private func sendLogin(
        studentId: String,
        moodleToken: String?,
        moodlePrivateToken: String?,
        platform: String,
        ticket: AccountSession.Ticket
    ) async throws -> LoginResult {
        struct LoginRequest: Encodable {
            let student_id: String
            let moodle_token: String?
            let moodle_private_token: String?
            let device_info: DeviceInfo
        }
        struct DeviceInfo: Encodable {
            let client_device_id: String
            let platform: String
            let app_version: String?
            let os_version: String?
            let device_model: String?
        }
        struct LoginResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
            let user: UserOut
            let device_id: String
        }
        struct UserOut: Decodable {
            let id: String
            let student_id: String
        }

        let body = LoginRequest(
            student_id: studentId,
            moodle_token: moodleToken,
            moodle_private_token: moodlePrivateToken,
            device_info: DeviceInfo(
                client_device_id: deviceUUID,
                platform: platform,
                app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                os_version: { let v = ProcessInfo.processInfo.operatingSystemVersion; return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" }(),
                device_model: PushDeviceModel.current
            )
        )

        let baseURL = baseURLProvider()
        var request = try BackendRequest("POST", "auth", "login").json(body, encoder: JSONEncoder())
        request.authenticated = false
        request.postsCredentials = true
        request.acceptsEveryStatus = true
        request.baseURL = baseURL

        guard signIns.isCurrent(ticket) else { throw CancellationError() }
        let response = try await backend.send(request)
        guard response.status == 200 else {
            await APIVersionGate.shared.note(statusCode: response.status, code: BackendClient.errorCode(in: response.data))
            throw AuthError.loginFailed
        }
        let result = try JSONDecoder().decode(LoginResponse.self, from: response.data)
        guard signIns.isCurrent(ticket) else { throw CancellationError() }
        store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
        // A refresh still out is the replaced pair's, so neither a caller nor a sign-out waits on it.
        refreshTask = nil
        // A session kept on another backend still has the device there; the launch retry sends it.
        departingSessions.forgetAll(on: baseURL)
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
        clearTokens()
    }

    /// Holds back the session's tokens until `endSession(on:)` has ended it, and returns the backend in
    /// use for its unregister. It runs at once on the caller's thread, so the tokens are held before
    /// an API endpoint change can store its new endpoint.
    nonisolated func beginSignOut() -> URL {
        signOutsStarting.withLock { $0 += 1 }
        return baseURLProvider()
    }

    func endSession(on backend: URL? = nil) async -> DepartingAccount {
        let baseURL = backend ?? baseURLProvider()
        let access = accessToken, refresh = refreshToken, expiry = expiresAt
        let refreshOut = refreshTask, ticket = signIns.ticket, uses = budget.uses
        logout()
        signOutsStarting.withLock { $0 = max($0 - 1, 0) }
        guard let refresh else { return DepartingAccount(accessToken: nil, baseURL: baseURL) }
        let departing = DepartingSession(
            refreshToken: refresh, uses: uses + (refreshOut == nil ? 0 : 1), baseURL: baseURL, id: UUID().uuidString
        )
        departingSessions.add(departing)
        let token = await unregisterToken(
            for: departing, access: access, expiry: expiry, refreshOut: refreshOut, ticket: ticket, uses: uses
        )
        return DepartingAccount(accessToken: token, baseURL: baseURL, sessionID: departing.id)
    }

    private func unregisterToken(
        for departing: DepartingSession, access: String?, expiry: Date, refreshOut: Task<String?, Never>?,
        ticket: AccountSession.Ticket, uses: Int
    ) async -> String? {
        if let access, Date.now < expiry.addingTimeInterval(-Self.signOutCallsWindow) { return access }
        if let refreshOut {
            _ = await refreshOut.value
            let late = lateRefreshes[departing.refreshToken].flatMap { $0.ticket == ticket ? $0 : nil }
            lateRefreshes = [:]
            if let late, let token = late.accessToken {
                if let next = late.refreshToken { keepDeparting(departing.rotated(to: next)) }
                return token
            }
            if let late, !late.mayResend {
                forgetDeparting(departing)
                return nil
            }
        }
        guard RefreshTokenUseBudget(uses: uses).allowsSend else {
            forgetDeparting(departing)
            return nil
        }
        if refreshToken == nil || !refreshTokenIsStored {
            guard tokens.saveConfirmed(Self.refreshTokenUsesKey, RefreshTokenUseBudget.spent.stored) else { return nil }
        }
        if !keepDeparting(departing.counted()) { forgetDeparting(departing) }
        return await refreshDeparting(departing)
    }

    nonisolated var hasDepartingSession: Bool { !departingSessions.load().isEmpty }

    nonisolated var departingSessionBackends: [URL] { departingSessions.load().map(\.baseURL) }

    func departingAccessToken() async -> String? {
        guard let session = departingSessions.load().first else { return nil }
        return await departingAccessToken(for: session)
    }

    private func departingAccessToken(for session: DepartingSession) async -> String? {
        guard session.budget.allowsSend else {
            forgetDeparting(session)
            return nil
        }
        guard keepDeparting(session.counted()) else { return nil }
        let token = await refreshDeparting(session)
        return keepsAlongside(session) ? token : nil
    }

    /// While signed in, only a session kept on another backend is sent: one on this backend was
    /// the device's, and the sign-in has given it to the new account.
    private func keepsAlongside(_ session: DepartingSession) -> Bool {
        refreshToken == nil || !Self.isSameBackend(session.baseURL, baseURLProvider())
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
        let backend = baseURLProvider()
        for session in departingSessions.load()
        where Self.retriesKeptSession(on: session.baseURL, signedIn: refreshToken != nil, backend: backend) {
            guard let token = await departingAccessToken(for: session) else { continue }
            let target = session.baseURL
            let account = DepartingAccount(accessToken: token, baseURL: target, sessionID: session.id)
            await unregisterDeparting(session, as: account) { await unregister(target) }
        }
    }

    func unregisterDeparting(as account: DepartingAccount, _ unregister: @MainActor @Sendable () async -> Bool) async {
        let session = account.sessionID.flatMap { id in departingSessions.load().first { $0.id == id } }
        await unregisterDeparting(session, as: account, unregister)
    }

    private func unregisterDeparting(
        _ session: DepartingSession?, as account: DepartingAccount, _ unregister: @MainActor @Sendable () async -> Bool
    ) async {
        let landed = await Self.$departing.withValue(account) {
            await unregister()
        }
        if landed, let session { forgetDeparting(session) }
    }

    @discardableResult
    private func keepDeparting(_ session: DepartingSession) -> Bool {
        keepsAlongside(session) && departingSessions.keep(session)
    }

    private func forgetDeparting(_ session: DepartingSession) {
        departingSessions.forget(session)
    }

    private func refreshDeparting(_ session: DepartingSession) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
        }
        let send = await postRefresh(session.refreshToken, on: session.baseURL)
        let status = send.reply?.1.statusCode
        if let status, status != 200 { await APIVersionGate.shared.note(statusCode: status) }
        // `/auth/refresh` answers a dead token with 401; a proxy's 403 or 408 spent nothing.
        if status == 401 {
            forgetDeparting(session)
            return nil
        }
        if !send.mayHaveUsed { keepDeparting(session) }
        guard status == 200, let data = send.reply?.0,
              let reply = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { return nil }
        keepDeparting(session.rotated(to: reply.refresh_token))
        return reply.access_token
    }

    private func clearTokens() {
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        tokens.delete(Self.accessTokenKey)
        tokens.delete(Self.expiresAtKey)
        if tokens.deleteConfirmed(Self.refreshTokenKey) { tokens.delete(Self.refreshTokenUsesKey) }
    }

    private func refresh() async -> String? {
        guard let refreshToken else { return nil }
        let ticket = signIns.ticket
        let endBackgroundTask = await beginBackgroundTask()
        let token = await refreshStoredToken(refreshToken, ticket: ticket)
        await endBackgroundTask()
        return token
    }

    /// Sends only the token it was started for, the one a sign-out counts a refresh still out against.
    private func refreshStoredToken(_ refreshToken: String, ticket: AccountSession.Ticket) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        // Read before the check: a sign-out holds the tokens before it stores another endpoint.
        // The resend goes where the first send went, whatever endpoint is stored meanwhile.
        let backend = baseURLProvider()
        guard signIns.isCurrent(ticket), signOutsStarting.withLock({ $0 == 0 }),
              self.refreshToken == refreshToken else { return nil }
        guard budget.allowsSend else {
            return await signedInAgain(since: ticket) ? accessToken : nil
        }
        var send = await postCounted(refreshToken, after: budget, on: backend)
        if send.reply == nil, !send.uncounted, signIns.isCurrent(ticket), send.budget.allowsSend {
            send = await postCounted(refreshToken, after: send.budget, on: backend)
        }
        if self.refreshToken == refreshToken { budget = send.budget }
        let reply = send.reply
        let mayResend = send.budget.allowsSend
        // A sign-in sends no refresh token, so a Keychain that refuses every count still leaves a session.
        if send.uncounted, await signedInAgain(since: ticket) { return accessToken }
        guard let (data, http) = reply else {
            noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: mayResend)
            return nil
        }

        if http.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: mayResend)
                return nil
            }
            // A sign-in that stored its pair meanwhile ended this token's session on the backend.
            guard signIns.isCurrent(ticket), self.refreshToken == refreshToken else {
                noteOvertaken(
                    ticket, sent: refreshToken, accessToken: result.access_token,
                    refreshToken: result.refresh_token, mayResend: false
                )
                return nil
            }
            store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
            return result.access_token
        }

        await APIVersionGate.shared.note(statusCode: http.statusCode)
        let turnedDown = Self.turnsDown(http.statusCode)
        guard signIns.isCurrent(ticket) else {
            noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: mayResend && !turnedDown)
            return nil
        }
        // A refusal of a token a sign-in has replaced says nothing of the sign-in's pair.
        guard turnedDown, self.refreshToken == refreshToken else { return nil }

        if await signedInAgain(since: ticket) { return accessToken }
        noteOvertaken(ticket, sent: refreshToken, accessToken: nil, mayResend: false)
        guard http.statusCode == 401, signIns.isCurrent(ticket), self.refreshToken == refreshToken else {
            return nil
        }
        clearTokens()
        return nil
    }

    private static func turnsDown(_ statusCode: Int) -> Bool {
        (400...499).contains(statusCode) && ![410, 429].contains(statusCode)
    }

    private func noteOvertaken(
        _ ticket: AccountSession.Ticket, sent: String, accessToken: String?, refreshToken: String? = nil, mayResend: Bool
    ) {
        guard !signIns.isCurrent(ticket) else { return }
        lateRefreshes[sent] = (ticket, accessToken, refreshToken, mayResend)
    }

    private func signedInAgain(since ticket: AccountSession.Ticket) async -> Bool {
        guard let relogin = onRefreshFailed else { return false }
        return await relogin() && signIns.isCurrent(ticket)
    }

    private struct RefreshSend {
        let reply: (Data, HTTPURLResponse)?
        let mayHaveUsed: Bool
    }

    /// `URLError`s of a request that never left the device: no network or no host to reach, a TLS
    /// handshake that failed, as behind a captive portal's sign-in page, or a request iOS refuses
    /// to send. A timeout, a dropped connection or a cancel may come after the token went out.
    private static let unsentErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
    ]

    /// `uncounted` when the Keychain refused the count, so nothing went out. A token a sign-in
    /// replaced meanwhile is not sent either, but it is no longer this refresh's to sign in for.
    /// The budget is counted before the send, so an app that ends during it still counts it.
    private func postCounted(
        _ refreshToken: String, after before: RefreshTokenUseBudget, on backend: URL
    ) async -> (reply: (Data, HTTPURLResponse)?, budget: RefreshTokenUseBudget, uncounted: Bool) {
        guard saveBudget(before.afterSend(mayHaveUsed: true), of: refreshToken) else {
            return (nil, before, self.refreshToken == refreshToken)
        }
        let send = await postRefresh(refreshToken, on: backend)
        let after = before.afterSend(mayHaveUsed: send.mayHaveUsed)
        _ = saveBudget(after, of: refreshToken)
        return (send.reply, after, false)
    }

    private func saveBudget(_ budget: RefreshTokenUseBudget, of token: String) -> Bool {
        guard refreshToken == token else { return false }
        if !refreshTokenIsStored {
            guard tokens.saveConfirmed(Self.refreshTokenKey, token) else { return false }
            refreshTokenIsStored = true
        }
        return tokens.saveConfirmed(Self.refreshTokenUsesKey, budget.stored)
    }

    private func postRefresh(_ refreshToken: String, on baseURL: URL) async -> RefreshSend {
        struct RefreshRequest: Encodable { let refresh_token: String }
        guard var request = try? BackendRequest("POST", "auth", "refresh")
            .json(RefreshRequest(refresh_token: refreshToken), encoder: JSONEncoder())
        else { return RefreshSend(reply: nil, mayHaveUsed: false) }
        request.authenticated = false
        request.postsCredentials = true
        request.acceptsEveryStatus = true
        request.timeout = refreshRequestTimeout
        request.baseURL = baseURL

        do {
            let response = try await backend.send(request)
            return RefreshSend(reply: (response.data, response.http), mayHaveUsed: !(400...499).contains(response.status))
        } catch {
            let unsent = (error as? URLError).map { Self.unsentErrors.contains($0.code) } ?? false
            return RefreshSend(reply: nil, mayHaveUsed: !unsent)
        }
    }

    private func store(access: String, refresh: String, expiresIn: Int) {
        self.accessToken = access
        self.refreshToken = refresh
        budget = RefreshTokenUseBudget()
        self.expiresAt = Date.now.addingTimeInterval(TimeInterval(expiresIn))
        tokens.save(Self.accessTokenKey, access)
        tokens.save(Self.expiresAtKey, String(expiresAt.timeIntervalSince1970))
        refreshTokenIsStored = tokens.saveConfirmed(Self.refreshTokenKey, refresh)
        if refreshTokenIsStored { tokens.delete(Self.refreshTokenUsesKey) }
    }

    nonisolated static func beginRefreshBackgroundTask() async -> @Sendable () async -> Void {
        await beginBackgroundTask(named: "Backend token refresh")
    }

    /// Starts a UIKit background task and returns what ends it. A Mac app is not suspended in the
    /// background, so only iOS needs one.
    nonisolated static func beginBackgroundTask(named name: String) async -> @Sendable () async -> Void {
        #if os(iOS)
        let task = await AppBackgroundTask(named: name)
        return { await task.end() }
        #else
        return {}
        #endif
    }

    enum AuthError: Error {
        case loginFailed
    }
}

#if os(iOS)
private final class AppBackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(named name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
