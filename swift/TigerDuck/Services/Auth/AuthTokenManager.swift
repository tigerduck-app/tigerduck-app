import Foundation
#if os(iOS)
import UIKit
#endif

/// Manages v3 JWT access and refresh tokens.
///
/// Tokens are stored in the Keychain. The access token is short-lived
/// (server default ~15 min); `validAccessToken()` transparently refreshes
/// when expired.
actor AuthTokenManager {
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast
    /// In-flight refresh, if any. The actor suspends at the network await
    /// inside `refresh()`, so without this a second concurrent
    /// `validAccessToken()` call would start its own refresh — and since the
    /// server rotates the refresh token on use, that second request would
    /// send an already-invalidated token and fail.
    private var refreshTask: Task<String?, Never>?
    /// Moved by ``logout()``: a login or refresh reply that comes back after a sign-out belongs
    /// to the account that left, so it stores nothing.
    private var signInGeneration = 0
    /// What a refresh that the sign-out of `generation` overtook got, for that sign-out's
    /// ``endSession()``: the pair of a reply, or whether the refresh token may go once more, which
    /// it may below ``refreshTokenUseLimit`` uses if the backend did not turn it down.
    private var lateRefresh: (generation: Int, accessToken: String?, refreshToken: String?, mayResend: Bool)?
    /// How many times the backend may have used the stored refresh token without this device
    /// keeping the pair: sends that may have reached it and got no reply, a server error or a 200
    /// it could not keep. The backend rotates a token sent again while its successor is unused and
    /// takes a third use for theft, which revokes every session of the device. A new pair starts
    /// it over. Kept with the tokens, as the app can end before the next refresh signs in again.
    private var refreshTokenUses = 0
    static let refreshTokenUseLimit = 2
    /// Whether the Keychain holds `refreshToken`. Until it does, the stored token keeps its count,
    /// so this one goes out only once it is stored too.
    private var refreshTokenIsStored = true

    /// Re-evaluated on every request, like ``PushAPIClient``, so an endpoint
    /// override applied at runtime moves login/refresh together with the
    /// data calls instead of leaving auth pinned to the launch-time host.
    private let baseURLProvider: @Sendable () -> URL
    private let deviceUUID: String
    private let session: URLSession
    private let refreshRequestTimeout: TimeInterval
    private let tokens: TokenStore
    /// Starts what keeps the app running until a refresh is done, and returns what ends it.
    private let beginBackgroundTask: @Sendable () async -> @Sendable () async -> Void
    private var onRefreshFailed: (() async -> Bool)?
    /// Signs in when ``validAccessToken()`` finds no session, so a protected request tries for
    /// one instead of going out without a token.
    private var onNoSession: (() async -> Void)?

    func setRefreshFailedHandler(_ handler: @escaping () async -> Bool) {
        onRefreshFailed = handler
    }

    func setNoSessionHandler(_ handler: @escaping () async -> Void) {
        onNoSession = handler
    }

    static let accessTokenKey = "v3_access_token"
    static let refreshTokenKey = "v3_refresh_token"
    static let expiresAtKey = "v3_token_expires_at"
    static let refreshTokenUsesKey = "v3_refresh_token_uses"
    /// ``DepartingSession``, as JSON.
    static let departingSessionKey = "v3_departing_session"

    /// A refresh with no reply by then goes once more, which the backend answers with a fresh pair
    /// while the pair it sent is unused, for up to 24 hours.
    static let refreshTimeout: TimeInterval = 20

    /// Set around the sign-out's device unregister, which goes out as the departing account after
    /// ``endSession()``. Everything else finds no session meanwhile.
    @TaskLocal static var departing: DepartingAccount?

    /// Wraps the token so a sign-out left without one sends nothing instead of signing in again.
    struct DepartingAccount: Sendable {
        let accessToken: String?
    }

    /// What ``endSession()`` keeps of the session it ended until the device's unregister lands as
    /// that account, for a later launch to send it then (``retryDepartingUnregister(_:)``): the
    /// newest refresh token, its sends that may have reached the backend with no reply kept, and the
    /// backend it belongs to, the endpoint at the sign-out. Its refresh and the unregister go there
    /// after the endpoint changes too, as no other server issued it.
    private nonisolated struct DepartingSession: Codable {
        var refreshToken: String
        var uses: Int
        var baseURL: URL

        /// This session with one more send.
        func counted() -> DepartingSession {
            DepartingSession(refreshToken: refreshToken, uses: uses + 1, baseURL: baseURL)
        }
    }

    /// How long the token ``endSession()`` hands out has to last: the unregister waits for a
    /// schedule upload still out, and each can take up to a 30 s timeout offline.
    static let signOutCallsWindow: TimeInterval = 120

    /// Where the tokens persist. Tests pass a stand-in so they leave the Keychain alone.
    nonisolated struct TokenStore: Sendable {
        let load: @Sendable (_ key: String) -> String?
        let save: @Sendable (_ key: String, _ value: String) -> Void
        let delete: @Sendable (_ key: String) -> Void
        /// `save` that answers whether the value is stored. A store without it is taken at its word.
        var confirmedSave: (@Sendable (_ key: String, _ value: String) -> Bool)?
        /// `delete` that answers whether the key is gone, taken at its word the same way.
        var confirmedDelete: (@Sendable (_ key: String) -> Bool)?

        static let keychain = TokenStore(
            load: { KeychainManager.loadString(key: $0) },
            save: { KeychainManager.saveString(key: $0, value: $1) },
            delete: { KeychainManager.delete(key: $0) },
            confirmedSave: { KeychainManager.saveStringReportingSuccess(key: $0, value: $1) },
            confirmedDelete: { KeychainManager.deleteReportingSuccess(key: $0) }
        )
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
        self.session = session
        self.refreshRequestTimeout = refreshTimeout
        self.tokens = tokens
        self.beginBackgroundTask = beginBackgroundTask
        self.accessToken = tokens.load(Self.accessTokenKey)
        self.refreshToken = tokens.load(Self.refreshTokenKey)
        if let raw = tokens.load(Self.expiresAtKey),
           let interval = TimeInterval(raw) {
            self.expiresAt = Date(timeIntervalSince1970: interval)
        }
        self.refreshTokenUses = tokens.load(Self.refreshTokenUsesKey).flatMap(Int.init) ?? 0
    }

    var isLoggedIn: Bool { refreshToken != nil }

    /// Returns a valid access token, refreshing if needed, or signing in first when there is no
    /// session. Nil if that fails. Concurrent callers coalesce onto a single refresh request.
    func validAccessToken() async -> String? {
        if let departing = Self.departing { return departing.accessToken }
        if refreshToken == nil, let onNoSession { await onNoSession() }
        guard refreshToken != nil else { return nil }
        if let token = accessToken, Date.now < expiresAt.addingTimeInterval(-30) {
            return token
        }
        if let inFlight = refreshTask {
            return await inFlight.value
        }
        // No suspension between the check above and this assignment, so only
        // one caller can create the task.
        let task = Task { await refresh() }
        refreshTask = task
        let token = await task.value
        refreshTask = nil
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

    /// Call after NTUST SSO succeeds. Posts the student ID and the Moodle token to /v3/auth/login,
    /// which needs no password, so the school password never reaches the backend.
    func login(
        studentId: String,
        moodleToken: String?,
        moodlePrivateToken: String?,
        platform: String
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

        var request = URLRequest(url: baseURLProvider().appendingPathComponent("auth/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let generation = signInGeneration
        let (data, response) = try await session.data(for: request, delegate: CredentialPostDelegate())
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            if let http = response as? HTTPURLResponse {
                await APIVersionGate.shared.note(statusCode: http.statusCode)
            }
            throw AuthError.loginFailed
        }
        let result = try JSONDecoder().decode(LoginResponse.self, from: data)
        guard signInGeneration == generation else { throw CancellationError() }
        store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
        // The backend has this device for the account signed in now, so an unregister a sign-out
        // left unsent no longer applies, and the same account's would revoke this session.
        forgetDepartingSession()
        return LoginResult(
            accessToken: result.access_token,
            refreshToken: result.refresh_token,
            expiresIn: result.expires_in,
            userId: result.user.id,
            deviceId: result.device_id
        )
    }

    func logout() {
        signInGeneration &+= 1
        clearTokens()
    }

    /// A sign-out's first step. The session ends at once, here and in the keychain: a sign-in that
    /// follows starts its own, a launch after the app is ended mid-sign-out has none, and a login
    /// or refresh still out stores nothing. Returns an access token for the device's unregister,
    /// which goes out as the departing account under ``departing``. One that would not outlast it
    /// is refreshed first, and a refresh already out is waited for instead. The refresh token is
    /// kept apart until the unregister lands (``DepartingSession``).
    func endSession() async -> String? {
        let access = accessToken, refresh = refreshToken, expiry = expiresAt
        let refreshOut = refreshTask, generation = signInGeneration, uses = refreshTokenUses
        logout()
        guard let refresh else { return nil }
        // A refresh still out may send the token once more.
        let departing = DepartingSession(
            refreshToken: refresh, uses: uses + (refreshOut == nil ? 0 : 1), baseURL: baseURLProvider()
        )
        keepDeparting(departing)
        if let access, Date.now < expiry.addingTimeInterval(-Self.signOutCallsWindow) { return access }
        // That refresh sent this token once, or twice after a lost reply, and the backend takes a
        // third use for theft, which revokes every session of the device. So it goes once more only
        // below the use limit, earlier refreshes included, and if the backend did not turn it down.
        if let refreshOut {
            _ = await refreshOut.value
            let late = lateRefresh?.generation == generation ? lateRefresh : nil
            lateRefresh = nil
            if let late, let token = late.accessToken {
                if let next = late.refreshToken {
                    keepDeparting(DepartingSession(refreshToken: next, uses: 0, baseURL: departing.baseURL))
                }
                return token
            }
            if let late, !late.mayResend {
                forgetDepartingSession()
                return nil
            }
        }
        guard uses < Self.refreshTokenUseLimit else {
            forgetDepartingSession()
            return nil
        }
        // The sign-out may not have deleted the token, so it is counted spent before its last send.
        // Not when a sign-in since has stored its own token over it: the count on disk is that token's.
        if refreshToken == nil || !refreshTokenIsStored {
            guard saveConfirmed(Self.refreshTokenUsesKey, String(Self.refreshTokenUseLimit)) else { return nil }
        }
        // Left uncounted, a later launch could send the token a third time.
        if !keepDeparting(departing.counted()) { forgetDepartingSession() }
        return await refreshDeparting(departing)
    }

    /// Whether a sign-out left the session it ended for an unregister a later launch sends.
    nonisolated var hasDepartingSession: Bool { storedDepartingSession() != nil }

    /// An access token for the device's unregister that a sign-out left unsent, from one refresh of
    /// the session it kept on the backend it belongs to. Nil when none is kept or the refresh brings
    /// none, and once a sign-in has started a session of its own. A session sent twice with no reply
    /// kept is forgotten unsent: the backend takes a third use for theft, which leaves the device
    /// registered with no session left to unregister it.
    func departingAccessToken() async -> String? {
        guard let session = storedDepartingSession() else { return nil }
        guard session.uses < Self.refreshTokenUseLimit else {
            forgetDepartingSession()
            return nil
        }
        guard keepDeparting(session.counted()) else { return nil }
        let token = await refreshDeparting(session)
        return refreshToken == nil ? token : nil
    }

    /// Sends the device's unregister that a sign-out left unsent (`unregister`, given the backend
    /// to send it to) as the departing account, to the backend the session it kept belongs to.
    func retryDepartingUnregister(_ unregister: @MainActor @Sendable (_ backend: URL) async -> Bool) async {
        guard let session = storedDepartingSession(), let token = await departingAccessToken() else { return }
        let target = session.baseURL
        await unregisterDeparting(accessToken: token) { await unregister(target) }
    }

    /// Sends the device's unregister (`unregister`) as the departing account with `accessToken`,
    /// and forgets the session kept for it once `unregister` answers that the server has it.
    func unregisterDeparting(accessToken: String?, _ unregister: @MainActor @Sendable () async -> Bool) async {
        let landed = await Self.$departing.withValue(DepartingAccount(accessToken: accessToken)) {
            await unregister()
        }
        if landed { forgetDepartingSession() }
    }

    /// Forgets the session a sign-out kept, once its unregister has landed or no longer applies.
    func forgetDepartingSession() {
        tokens.delete(Self.departingSessionKey)
    }

    private nonisolated func storedDepartingSession() -> DepartingSession? {
        tokens.load(Self.departingSessionKey)
            .flatMap { try? JSONDecoder().decode(DepartingSession.self, from: Data($0.utf8)) }
    }

    /// Stores `session`, unless a sign-in since has started a session of its own, which the
    /// departing account's unregister no longer concerns. Returns whether it is stored.
    @discardableResult
    private func keepDeparting(_ session: DepartingSession) -> Bool {
        guard refreshToken == nil, let data = try? JSONEncoder().encode(session) else { return false }
        return saveConfirmed(Self.departingSessionKey, String(decoding: data, as: UTF8.self))
    }

    /// Sends the departing session's refresh token, its send counted already, and keeps what the
    /// reply brings: the next token, the count as it was for a send that never reached the backend,
    /// or nothing once the backend turned the token down. Returns the reply's access token.
    private func refreshDeparting(_ session: DepartingSession) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
        }
        let send = await postRefresh(session.refreshToken, on: session.baseURL)
        let status = send.reply?.1.statusCode
        if let status, status != 200 { await APIVersionGate.shared.note(statusCode: status) }
        if let status, Self.turnsDown(status) {
            forgetDepartingSession()
            return nil
        }
        if !send.mayHaveUsed { keepDeparting(session) }
        guard status == 200, let data = send.reply?.0,
              let reply = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { return nil }
        keepDeparting(DepartingSession(refreshToken: reply.refresh_token, uses: 0, baseURL: session.baseURL))
        return reply.access_token
    }

    private func clearTokens() {
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        tokens.delete(Self.accessTokenKey)
        tokens.delete(Self.expiresAtKey)
        // A token whose delete did not take is there for the next launch, so its count stays too.
        if deleteConfirmed(Self.refreshTokenKey) { tokens.delete(Self.refreshTokenUsesKey) }
    }

    private func refresh() async -> String? {
        guard refreshToken != nil else { return nil }
        let generation = signInGeneration
        // Suspended before the reply is stored, the app loses the pair the server rotated to, and
        // the old token it sends later revokes every session of the device.
        let endBackgroundTask = await beginBackgroundTask()
        let token = await refreshStoredToken(generation: generation)
        await endBackgroundTask()
        return token
    }

    private func refreshStoredToken(generation: Int) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        // Read after the await above, together with its uses.
        guard signInGeneration == generation, let refreshToken else { return nil }
        // A request with no reply may still have rotated the token. While the pair it sent is unused,
        // for up to 24 hours, the backend answers the old token once more with a fresh pair; a
        // second reuse is taken for theft, so past the limit only a sign-in brings a session.
        guard refreshTokenUses < Self.refreshTokenUseLimit else {
            return await signedInAgain(since: generation) ? accessToken : nil
        }
        var send = await postCounted(refreshToken, usedBefore: refreshTokenUses)
        if send.reply == nil, signInGeneration == generation, send.uses < Self.refreshTokenUseLimit {
            send = await postCounted(refreshToken, usedBefore: send.uses)
        }
        let uses = send.uses
        if self.refreshToken == refreshToken { refreshTokenUses = uses }
        let reply = send.reply
        let mayResend = uses < Self.refreshTokenUseLimit
        guard let (data, http) = reply else {
            noteOvertaken(generation, accessToken: nil, mayResend: mayResend)
            return nil
        }

        if http.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else {
                noteOvertaken(generation, accessToken: nil, mayResend: mayResend)
                return nil
            }
            guard signInGeneration == generation else {
                noteOvertaken(
                    generation, accessToken: result.access_token, refreshToken: result.refresh_token, mayResend: false
                )
                return nil
            }
            store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
            return result.access_token
        }

        await APIVersionGate.shared.note(statusCode: http.statusCode)
        // A 4xx means the backend turned this token down, so a relogin is tried. A 429 from the
        // per-IP limit, a 410 (API retired) and a 5xx say nothing about the token and keep it.
        let turnedDown = Self.turnsDown(http.statusCode)
        // Answered after a sign-out: the session it turned down is the departing account's.
        guard signInGeneration == generation else {
            noteOvertaken(generation, accessToken: nil, mayResend: mayResend && !turnedDown)
            return nil
        }
        guard turnedDown else { return nil }

        if await signedInAgain(since: generation) { return accessToken }
        // If a sign-out overtook the relogin, its `endSession()` sends no token the backend turned down.
        noteOvertaken(generation, accessToken: nil, mayResend: false)
        // Only a 401 says the token is dead. Another 4xx keeps it, so a relogin that cannot run
        // behind a locked screen does not sign the device out. A sign-out during the relogin
        // leaves the next account's session alone.
        guard http.statusCode == 401, signInGeneration == generation else { return nil }
        // Not `logout()`: the account has not signed out, so a relogin that another caller has
        // in flight may still store its pair.
        clearTokens()
        return nil
    }

    /// Whether a refresh answered `statusCode` turned its token down: a 4xx but a 429 or a 410.
    private static func turnsDown(_ statusCode: Int) -> Bool {
        (400...499).contains(statusCode) && ![410, 429].contains(statusCode)
    }

    /// Keeps what a refresh got for the sign-out of `generation`, if one overtook it.
    private func noteOvertaken(_ generation: Int, accessToken: String?, refreshToken: String? = nil, mayResend: Bool) {
        guard signInGeneration != generation else { return }
        lateRefresh = (generation, accessToken, refreshToken, mayResend)
    }

    /// Whether the relogin that stands in for a refresh worked, with no sign-out meanwhile.
    private func signedInAgain(since generation: Int) async -> Bool {
        guard let relogin = onRefreshFailed else { return false }
        return await relogin() && signInGeneration == generation
    }

    /// What one refresh request got: the HTTP reply, nil when none came back, as on a timeout,
    /// and whether the backend may have used the token. It answers a 4xx before it touches the
    /// token, and a request that failed before it left the device never reached it.
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

    /// Sends `refreshToken` with its count on disk raised first, since the app can end before the
    /// reply, and set after to what the send may have cost. Returns the reply and that count. A
    /// count that could not be raised sends nothing, as a request that never left does.
    private func postCounted(
        _ refreshToken: String, usedBefore uses: Int
    ) async -> (reply: (Data, HTTPURLResponse)?, uses: Int) {
        guard saveUses(uses + 1, of: refreshToken) else { return (nil, uses) }
        let send = await postRefresh(refreshToken, on: baseURLProvider())
        let total = send.mayHaveUsed ? uses + 1 : uses
        _ = saveUses(total, of: refreshToken)
        return (send.reply, total)
    }

    /// Whether the count is stored, only while `token` is the stored one: a sign-out or a sign-in
    /// may have replaced it meanwhile.
    private func saveUses(_ uses: Int, of token: String) -> Bool {
        guard refreshToken == token else { return false }
        if !refreshTokenIsStored {
            guard saveConfirmed(Self.refreshTokenKey, token) else { return false }
            refreshTokenIsStored = true
        }
        return saveConfirmed(Self.refreshTokenUsesKey, String(uses))
    }

    private func saveConfirmed(_ key: String, _ value: String) -> Bool {
        if let confirmedSave = tokens.confirmedSave { return confirmedSave(key, value) }
        tokens.save(key, value)
        return true
    }

    private func deleteConfirmed(_ key: String) -> Bool {
        if let confirmedDelete = tokens.confirmedDelete { return confirmedDelete(key) }
        tokens.delete(key)
        return true
    }

    private func postRefresh(_ refreshToken: String, on baseURL: URL) async -> RefreshSend {
        struct RefreshRequest: Encodable { let refresh_token: String }
        var request = URLRequest(
            url: baseURL.appendingPathComponent("auth/refresh"),
            timeoutInterval: refreshRequestTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshRequest(refresh_token: refreshToken))

        do {
            let (data, response) = try await session.data(for: request, delegate: CredentialPostDelegate())
            guard let http = response as? HTTPURLResponse else { return RefreshSend(reply: nil, mayHaveUsed: true) }
            return RefreshSend(reply: (data, http), mayHaveUsed: !(400...499).contains(http.statusCode))
        } catch {
            let unsent = (error as? URLError).map { Self.unsentErrors.contains($0.code) } ?? false
            return RefreshSend(reply: nil, mayHaveUsed: !unsent)
        }
    }

    private func store(access: String, refresh: String, expiresIn: Int) {
        self.accessToken = access
        self.refreshToken = refresh
        refreshTokenUses = 0
        self.expiresAt = Date.now.addingTimeInterval(TimeInterval(expiresIn))
        tokens.save(Self.accessTokenKey, access)
        tokens.save(Self.expiresAtKey, String(expiresAt.timeIntervalSince1970))
        refreshTokenIsStored = saveConfirmed(Self.refreshTokenKey, refresh)
        // After the new token: ending in between keeps the old count on the new token, which only
        // signs in again early, while the reverse would send the old token uncounted.
        if refreshTokenIsStored { tokens.delete(Self.refreshTokenUsesKey) }
    }

    /// The default for `beginBackgroundTask`.
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
/// A UIKit background task, which its work and its expiry can both end.
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
