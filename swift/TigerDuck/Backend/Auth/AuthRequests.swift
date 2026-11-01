import Foundation

nonisolated struct AuthRequests: Sendable {
    let baseURL: @Sendable () -> URL
    let deviceUUID: String
    let backend: BackendClient
    let refreshTimeout: TimeInterval

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

    func login(
        studentId: String, moodleToken: String?, moodlePrivateToken: String?, platform: String, to baseURL: URL
    ) throws -> BackendRequest {
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

        var request = try BackendRequest("POST", "auth", "login").json(body, encoder: JSONEncoder())
        request.authenticated = false
        request.postsCredentials = true
        request.acceptsEveryStatus = true
        request.baseURLOverride = baseURL
        return request
    }

    func send(login request: BackendRequest) async throws -> LoginResponse {
        let response = try await backend.send(request)
        guard response.status == 200 else {
            await APIVersionGate.shared.note(statusCode: response.status, code: BackendClient.errorCode(in: response.data))
            throw AuthTokenManager.AuthError.loginFailed
        }
        return try JSONDecoder().decode(LoginResponse.self, from: response.data)
    }

    struct RefreshSend {
        let reply: (Data, HTTPURLResponse)?
        let mayHaveUsed: Bool

        var status: Int? { reply?.1.statusCode }

        var endedSession: Bool { status == 401 }

        var turnedDown: Bool { status.map { (400...499).contains($0) && ![410, 429].contains($0) } ?? false }
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

    func postRefresh(_ refreshToken: String, on baseURL: URL) async -> RefreshSend {
        struct RefreshRequest: Encodable { let refresh_token: String }
        guard var request = try? BackendRequest("POST", "auth", "refresh")
            .json(RefreshRequest(refresh_token: refreshToken), encoder: JSONEncoder())
        else { return RefreshSend(reply: nil, mayHaveUsed: false) }
        request.authenticated = false
        request.postsCredentials = true
        request.acceptsEveryStatus = true
        request.timeout = refreshTimeout
        request.baseURLOverride = baseURL

        do {
            let response = try await backend.send(request)
            return RefreshSend(reply: (response.data, response.http), mayHaveUsed: !(400...499).contains(response.status))
        } catch {
            let unsent = (error as? URLError).map { Self.unsentErrors.contains($0.code) } ?? false
            return RefreshSend(reply: nil, mayHaveUsed: !unsent)
        }
    }
}
