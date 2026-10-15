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
    /// ``endSession()``: the access token of a reply, or whether the refresh token may go once
    /// more, which it may below ``refreshTokenUseLimit`` uses if the backend did not turn it down.
    private var lateRefresh: (generation: Int, accessToken: String?, mayResend: Bool)?
    /// How many times the backend may have used the stored refresh token without this device
    /// keeping the pair: sends that may have reached it and got no reply, a server error or a 200
    /// it could not keep. The backend rotates a token sent again while its successor is unused and
    /// takes a third use for theft, which revokes every session of the device. A new pair starts
    /// it over.
    private var refreshTokenUses = 0
    static let refreshTokenUseLimit = 2

    /// Re-evaluated on every request, like ``PushAPIClient``, so an endpoint
    /// override applied at runtime moves login/refresh together with the
    /// data calls instead of leaving auth pinned to the launch-time host.
    private let baseURLProvider: @Sendable () -> URL
    private let deviceUUID: String
    private let session: URLSession
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

    /// How long the token ``endSession()`` hands out has to last: the unregister waits for a
    /// schedule upload still out, and each can take up to a 30 s timeout offline.
    static let signOutCallsWindow: TimeInterval = 120

    /// Where the tokens persist. Tests pass a stand-in so they leave the Keychain alone.
    nonisolated struct TokenStore: Sendable {
        let load: @Sendable (_ key: String) -> String?
        let save: @Sendable (_ key: String, _ value: String) -> Void
        let delete: @Sendable (_ key: String) -> Void

        static let keychain = TokenStore(
            load: { KeychainManager.loadString(key: $0) },
            save: { KeychainManager.saveString(key: $0, value: $1) },
            delete: { KeychainManager.delete(key: $0) }
        )
    }

    init(
        baseURLProvider: @escaping @Sendable () -> URL = { PushServerConfig.resolveServerURL() },
        deviceUUID: String,
        session: URLSession = .shared,
        tokens: TokenStore = .keychain,
        beginBackgroundTask: @escaping @Sendable () async -> @Sendable () async -> Void
            = AuthTokenManager.beginRefreshBackgroundTask
    ) {
        self.baseURLProvider = baseURLProvider
        self.deviceUUID = deviceUUID
        self.session = session
        self.tokens = tokens
        self.beginBackgroundTask = beginBackgroundTask
        self.accessToken = tokens.load(Self.accessTokenKey)
        self.refreshToken = tokens.load(Self.refreshTokenKey)
        if let raw = tokens.load(Self.expiresAtKey),
           let interval = TimeInterval(raw) {
            self.expiresAt = Date(timeIntervalSince1970: interval)
        }
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
    /// is refreshed first, and the pair that brings is not kept; a refresh already out is waited
    /// for instead.
    func endSession() async -> String? {
        let access = accessToken, refresh = refreshToken, expiry = expiresAt
        let refreshOut = refreshTask, generation = signInGeneration, uses = refreshTokenUses
        logout()
        guard let refresh else { return nil }
        if let access, Date.now < expiry.addingTimeInterval(-Self.signOutCallsWindow) { return access }
        // That refresh sent this token once, or twice after a lost reply, and the backend takes a
        // third use for theft, which revokes every session of the device. So it goes once more only
        // below the use limit, earlier refreshes included, and if the backend did not turn it down.
        if let refreshOut {
            _ = await refreshOut.value
            let late = lateRefresh?.generation == generation ? lateRefresh : nil
            lateRefresh = nil
            if let token = late?.accessToken { return token }
            if let late, !late.mayResend { return nil }
        }
        guard uses < Self.refreshTokenUseLimit else { return nil }
        struct RefreshResponse: Decodable { let access_token: String }
        guard let (data, http) = await postRefresh(refresh).reply, http.statusCode == 200 else { return nil }
        return (try? JSONDecoder().decode(RefreshResponse.self, from: data))?.access_token
    }

    private func clearTokens() {
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        tokens.delete(Self.accessTokenKey)
        tokens.delete(Self.refreshTokenKey)
        tokens.delete(Self.expiresAtKey)
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
        var uses = refreshTokenUses
        guard uses < Self.refreshTokenUseLimit else {
            return await signedInAgain(since: generation) ? accessToken : nil
        }
        var send = await postRefresh(refreshToken)
        if send.mayHaveUsed { uses += 1 }
        if send.reply == nil, signInGeneration == generation, uses < Self.refreshTokenUseLimit {
            send = await postRefresh(refreshToken)
            if send.mayHaveUsed { uses += 1 }
        }
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
                noteOvertaken(generation, accessToken: result.access_token, mayResend: false)
                return nil
            }
            store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
            return result.access_token
        }

        await APIVersionGate.shared.note(statusCode: http.statusCode)
        // A 4xx means the backend turned this token down, so a relogin is tried. A 429 from the
        // per-IP limit, a 410 (API retired) and a 5xx say nothing about the token and keep it.
        let turnedDown = (400...499).contains(http.statusCode) && ![410, 429].contains(http.statusCode)
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

    /// Keeps what a refresh got for the sign-out of `generation`, if one overtook it.
    private func noteOvertaken(_ generation: Int, accessToken: String?, mayResend: Bool) {
        guard signInGeneration != generation else { return }
        lateRefresh = (generation, accessToken, mayResend)
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

    private func postRefresh(_ refreshToken: String) async -> RefreshSend {
        struct RefreshRequest: Encodable { let refresh_token: String }
        var request = URLRequest(
            url: baseURLProvider().appendingPathComponent("auth/refresh"),
            timeoutInterval: Self.refreshTimeout
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
        tokens.save(Self.refreshTokenKey, refresh)
        tokens.save(Self.expiresAtKey, String(expiresAt.timeIntervalSince1970))
    }

    /// The default for `beginBackgroundTask`. A Mac app is not suspended in the background, so
    /// only iOS needs one.
    nonisolated static func beginRefreshBackgroundTask() async -> @Sendable () async -> Void {
        #if os(iOS)
        let task = await RefreshBackgroundTask()
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
/// A UIKit background task, which the refresh and its expiry can both end.
private final class RefreshBackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init() {
        id = UIApplication.shared.beginBackgroundTask(withName: "Backend token refresh") { [weak self] in
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
