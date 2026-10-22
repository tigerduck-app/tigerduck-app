import Foundation
#if os(iOS)
import UIKit
#endif

actor AuthTokenManager {
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast
    private var refreshTask: Task<String?, Never>?
    private var signInGeneration = 0
    private var lateRefresh: (generation: Int, accessToken: String?, refreshToken: String?, mayResend: Bool)?
    private var refreshTokenUses = 0
    static let refreshTokenUseLimit = 2
    private var refreshTokenIsStored = true

    private let baseURLProvider: @Sendable () -> URL
    private let deviceUUID: String
    private let session: URLSession
    private let refreshRequestTimeout: TimeInterval
    private let tokens: TokenStore
    private let beginBackgroundTask: @Sendable () async -> @Sendable () async -> Void
    private var onRefreshFailed: (() async -> Bool)?
    private var onNoSession: (() async -> Void)?

    func setRefreshFailedHandler(_ handler: @escaping () async -> Bool) {
        onRefreshFailed = handler
    /// How many times the backend may have used the stored refresh token without this device
    /// keeping the pair: sends that may have reached it and got no reply, a server error or a 200
    /// it could not keep. The backend rotates a token sent again while its successor is unused and
    /// takes a third use for theft, which revokes every session of the device. A new pair starts
    /// it over. Kept with the tokens, as the app can end before the next refresh signs in again.
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

    struct DepartingAccount: Sendable {
        let accessToken: String?
    }

    private nonisolated struct DepartingSession: Codable {
        var refreshToken: String
        var uses: Int
        var baseURL: URL

        func counted() -> DepartingSession {
            DepartingSession(refreshToken: refreshToken, uses: uses + 1, baseURL: baseURL)
        }
    }

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

    func endSession() async -> String? {
        let access = accessToken, refresh = refreshToken, expiry = expiresAt
        let refreshOut = refreshTask, generation = signInGeneration, uses = refreshTokenUses
        logout()
        guard let refresh else { return nil }
        let departing = DepartingSession(
            refreshToken: refresh, uses: uses + (refreshOut == nil ? 0 : 1), baseURL: baseURLProvider()
        )
        keepDeparting(departing)
        if let access, Date.now < expiry.addingTimeInterval(-Self.signOutCallsWindow) { return access }
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
        if refreshToken == nil || !refreshTokenIsStored {
            guard saveConfirmed(Self.refreshTokenUsesKey, String(Self.refreshTokenUseLimit)) else { return nil }
        }
        if !keepDeparting(departing.counted()) { forgetDepartingSession() }
        return await refreshDeparting(departing)
    }

    nonisolated var hasDepartingSession: Bool { storedDepartingSession() != nil }

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

    func retryDepartingUnregister(_ unregister: @MainActor @Sendable (_ backend: URL) async -> Bool) async {
        guard let session = storedDepartingSession(), let token = await departingAccessToken() else { return }
        let target = session.baseURL
        await unregisterDeparting(accessToken: token) { await unregister(target) }
    }

    func unregisterDeparting(accessToken: String?, _ unregister: @MainActor @Sendable () async -> Bool) async {
        let landed = await Self.$departing.withValue(DepartingAccount(accessToken: accessToken)) {
            await unregister()
        }
        if landed { forgetDepartingSession() }
    }

    func forgetDepartingSession() {
        tokens.delete(Self.departingSessionKey)
    }

    private nonisolated func storedDepartingSession() -> DepartingSession? {
        tokens.load(Self.departingSessionKey)
            .flatMap { try? JSONDecoder().decode(DepartingSession.self, from: Data($0.utf8)) }
    }

    @discardableResult
    private func keepDeparting(_ session: DepartingSession) -> Bool {
        guard refreshToken == nil, let data = try? JSONEncoder().encode(session) else { return false }
        return saveConfirmed(Self.departingSessionKey, String(decoding: data, as: UTF8.self))
    }

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
        if deleteConfirmed(Self.refreshTokenKey) { tokens.delete(Self.refreshTokenUsesKey) }
    }

    private func refresh() async -> String? {
        guard refreshToken != nil else { return nil }
        let generation = signInGeneration
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

        guard signInGeneration == generation, let refreshToken else { return nil }
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
        let turnedDown = Self.turnsDown(http.statusCode)
        guard signInGeneration == generation else {
            noteOvertaken(generation, accessToken: nil, mayResend: mayResend && !turnedDown)
            return nil
        }
        guard turnedDown else { return nil }

        if await signedInAgain(since: generation) { return accessToken }
        noteOvertaken(generation, accessToken: nil, mayResend: false)
        guard http.statusCode == 401, signInGeneration == generation else { return nil }
        clearTokens()
        return nil
    }

    private static func turnsDown(_ statusCode: Int) -> Bool {
        (400...499).contains(statusCode) && ![410, 429].contains(statusCode)
    }

    private func noteOvertaken(_ generation: Int, accessToken: String?, refreshToken: String? = nil, mayResend: Bool) {
        guard signInGeneration != generation else { return }
        lateRefresh = (generation, accessToken, refreshToken, mayResend)
    }

    private func signedInAgain(since generation: Int) async -> Bool {
        guard let relogin = onRefreshFailed else { return false }
        return await relogin() && signInGeneration == generation
    }

    private struct RefreshSend {
        let reply: (Data, HTTPURLResponse)?
        let mayHaveUsed: Bool
    }

    private static let unsentErrors: Set<URLError.Code> = [
        .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff, .callIsActive,
        .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
        .clientCertificateRejected, .clientCertificateRequired,
        .appTransportSecurityRequiresSecureConnection, .badURL, .unsupportedURL,
    ]

    private func postCounted(
        _ refreshToken: String, usedBefore uses: Int
    ) async -> (reply: (Data, HTTPURLResponse)?, uses: Int) {
        guard saveUses(uses + 1, of: refreshToken) else { return (nil, uses) }
        let send = await postRefresh(refreshToken, on: baseURLProvider())
        let total = send.mayHaveUsed ? uses + 1 : uses
        _ = saveUses(total, of: refreshToken)
        return (send.reply, total)
    }

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
        if refreshTokenIsStored { tokens.delete(Self.refreshTokenUsesKey) }
    }

    nonisolated static func beginRefreshBackgroundTask() async -> @Sendable () async -> Void {
        await beginBackgroundTask(named: "Backend token refresh")
    }

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

    /// `URLError`s of a request that never left the device: no network or no host to reach, a TLS
    /// handshake that failed, as behind a captive portal's sign-in page, or a request iOS refuses
    /// to send. A timeout, a dropped connection or a cancel may come after the token went out.
    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
#endif
    /// Starts a UIKit background task and returns what ends it. A Mac app is not suspended in the
    /// background, so only iOS needs one.
