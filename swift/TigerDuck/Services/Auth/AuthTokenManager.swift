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
    /// The access token of a refresh reply that came back after the sign-out of `generation`, for
    /// that sign-out's ``endSession()``.
    private var lateRefresh: (generation: Int, accessToken: String)?

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

    /// Well under the backend's 60 s reuse grace, so the retry after a timeout still falls in it.
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
        let (data, response) = try await session.data(for: request)
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
        let refreshOut = refreshTask, generation = signInGeneration
        logout()
        guard let refresh else { return nil }
        if let access, Date.now < expiry.addingTimeInterval(-Self.signOutCallsWindow) { return access }
        // That refresh has sent this token, twice after a lost reply, and the backend takes a
        // third use for theft, which revokes the device's sessions and the unregister with them.
        if let refreshOut {
            _ = await refreshOut.value
            guard let late = lateRefresh, late.generation == generation else { return nil }
            lateRefresh = nil
            return late.accessToken
        }
        struct RefreshResponse: Decodable { let access_token: String }
        guard let (data, http) = await postRefresh(refresh), http.statusCode == 200 else { return nil }
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
        guard let refreshToken else { return nil }
        let generation = signInGeneration
        // Suspended before the reply is stored, the app loses the pair the server rotated to, and
        // the old token it sends later revokes every session of the device.
        let endBackgroundTask = await beginBackgroundTask()
        let token = await refresh(sending: refreshToken, generation: generation)
        await endBackgroundTask()
        return token
    }

    private func refresh(sending refreshToken: String, generation: Int) async -> String? {
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }

        // A request with no reply may still have rotated the token. For 60 s the backend answers
        // the old token once more with a fresh pair; a second reuse is taken for theft.
        var reply = await postRefresh(refreshToken)
        if reply == nil, signInGeneration == generation {
            reply = await postRefresh(refreshToken)
        }
        guard let (data, http) = reply else { return nil }

        if http.statusCode == 200 {
            guard let result = try? JSONDecoder().decode(RefreshResponse.self, from: data) else { return nil }
            guard signInGeneration == generation else {
                lateRefresh = (generation, result.access_token)
                return nil
            }
            store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
            return result.access_token
        }

        await APIVersionGate.shared.note(statusCode: http.statusCode)
        // Answered after a sign-out: the session it turned down is the departing account's.
        guard signInGeneration == generation else { return nil }
        // A 4xx means the backend turned this token down, so a relogin is tried. A 429 from the
        // per-IP limit, a 410 (API retired) and a 5xx say nothing about the token and keep it.
        guard (400...499).contains(http.statusCode), ![410, 429].contains(http.statusCode) else {
            return nil
        }

        if let relogin = onRefreshFailed, await relogin(), signInGeneration == generation {
            return accessToken
        }
        // Only a 401 says the token is dead. Another 4xx keeps it, so a relogin that cannot run
        // behind a locked screen does not sign the device out. A sign-out during the relogin
        // leaves the next account's session alone.
        guard http.statusCode == 401, signInGeneration == generation else { return nil }
        // Not `logout()`: the account has not signed out, so a relogin that another caller has
        // in flight may still store its pair.
        clearTokens()
        return nil
    }

    /// Sends one refresh request. Nil when no HTTP reply came back, as on a timeout.
    private func postRefresh(_ refreshToken: String) async -> (Data, HTTPURLResponse)? {
        struct RefreshRequest: Encodable { let refresh_token: String }
        var request = URLRequest(
            url: baseURLProvider().appendingPathComponent("auth/refresh"),
            timeoutInterval: Self.refreshTimeout
        )
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshRequest(refresh_token: refreshToken))

        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse
        else {
            return nil
        }
        return (data, http)
    }

    private func store(access: String, refresh: String, expiresIn: Int) {
        self.accessToken = access
        self.refreshToken = refresh
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
