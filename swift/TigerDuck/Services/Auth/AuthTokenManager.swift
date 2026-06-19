import Foundation

/// Manages v3 JWT access and refresh tokens.
///
/// Tokens are stored in the Keychain. The access token is short-lived
/// (server default ~15 min); `validAccessToken()` transparently refreshes
/// when expired.
actor AuthTokenManager {
    private var accessToken: String?
    private var refreshToken: String?
    private var expiresAt: Date = .distantPast

    private let baseURL: String
    private let deviceUUID: String

    static let accessTokenKey = "v3_access_token"
    static let refreshTokenKey = "v3_refresh_token"
    static let expiresAtKey = "v3_token_expires_at"

    init(baseURL: String, deviceUUID: String) {
        self.baseURL = baseURL
        self.deviceUUID = deviceUUID
        self.accessToken = KeychainManager.loadString(key: Self.accessTokenKey)
        self.refreshToken = KeychainManager.loadString(key: Self.refreshTokenKey)
        if let raw = KeychainManager.loadString(key: Self.expiresAtKey),
           let interval = TimeInterval(raw) {
            self.expiresAt = Date(timeIntervalSince1970: interval)
        }
    }

    var isLoggedIn: Bool { refreshToken != nil }

    /// Returns a valid access token, refreshing if needed. Nil if not logged in.
    func validAccessToken() async -> String? {
        guard refreshToken != nil else { return nil }
        if let token = accessToken, Date.now < expiresAt.addingTimeInterval(-30) {
            return token
        }
        return await refresh()
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

    /// Call after NTUST SSO succeeds. Posts credentials to /v3/auth/login.
    func login(
        studentId: String,
        password: String,
        moodleToken: String?,
        moodlePrivateToken: String?,
        platform: String
    ) async throws -> LoginResult {
        struct LoginRequest: Encodable {
            let student_id: String
            let password: String
            let moodle_token: String?
            let moodle_private_token: String?
            let device_info: DeviceInfo
        }
        struct DeviceInfo: Encodable {
            let client_device_id: String
            let platform: String
            let app_version: String?
            let os_version: String?
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
            password: password,
            moodle_token: moodleToken,
            moodle_private_token: moodlePrivateToken,
            device_info: DeviceInfo(
                client_device_id: deviceUUID,
                platform: platform,
                app_version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                os_version: ProcessInfo.processInfo.operatingSystemVersionString
            )
        )

        var request = URLRequest(url: URL(string: "\(baseURL)/auth/login")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw AuthError.loginFailed
        }
        let result = try JSONDecoder().decode(LoginResponse.self, from: data)
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
        accessToken = nil
        refreshToken = nil
        expiresAt = .distantPast
        KeychainManager.delete(key: Self.accessTokenKey)
        KeychainManager.delete(key: Self.refreshTokenKey)
        KeychainManager.delete(key: Self.expiresAtKey)
    }

    private func refresh() async -> String? {
        guard let refreshToken else { return nil }
        struct RefreshRequest: Encodable { let refresh_token: String }
        struct RefreshResponse: Decodable {
            let access_token: String
            let refresh_token: String
            let expires_in: Int
        }
        var request = URLRequest(url: URL(string: "\(baseURL)/auth/refresh")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(RefreshRequest(refresh_token: refreshToken))

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let result = try? JSONDecoder().decode(RefreshResponse.self, from: data)
        else {
            logout()
            return nil
        }
        store(access: result.access_token, refresh: result.refresh_token, expiresIn: result.expires_in)
        return result.access_token
    }

    private func store(access: String, refresh: String, expiresIn: Int) {
        self.accessToken = access
        self.refreshToken = refresh
        self.expiresAt = Date.now.addingTimeInterval(TimeInterval(expiresIn))
        KeychainManager.saveString(key: Self.accessTokenKey, value: access)
        KeychainManager.saveString(key: Self.refreshTokenKey, value: refresh)
        KeychainManager.saveString(key: Self.expiresAtKey, value: String(expiresAt.timeIntervalSince1970))
    }

    enum AuthError: Error {
        case loginFailed
    }
}
