import Foundation

enum LibraryServiceError: LocalizedError {
    case credentialsNotFound
    case loginFailed(String)
    case qrGenerationFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound: String(localized: "error_library_credentials_not_found")
        case .loginFailed(let msg): String(format: String(localized: "error_library_login_failed_format"), msg)
        case .qrGenerationFailed(let msg): String(format: String(localized: "error_qr_generation_failed_format"), msg)
        case .networkError(let e): String(format: String(localized: "error_network_format"), e.localizedDescription)
        }
    }
}

enum LibraryService {
    private static let baseURL = "https://api.lib.ntust.edu.tw/v1"

    /// Service-owned URLSession with explicit timeouts. `URLSession.shared`'s
    /// 60s default lets a stalled library API hold the QR refresh task open
    /// long enough for the displayed token to expire on the user, and any
    /// cached response from the system shared cache could leak between
    /// accounts after a logout/re-login.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    /// Validate that the response is HTTP 2xx before decoding. Without this
    /// a 5xx HTML error page or an auth-redirect surfaces to the caller as
    /// a confusing decode failure ("the data couldn't be read because it
    /// isn't in the correct format") instead of an actionable network/server
    /// error.
    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw LibraryServiceError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let underlying = URLError(
                .badServerResponse,
                userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(http.statusCode)",
                    "statusCode": http.statusCode,
                ]
            )
            throw LibraryServiceError.networkError(underlying)
        }
    }

    // MARK: - Credential Management

    static var storedUsername: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryUsername)
    }

    static func saveCredentials(username: String, password: String) {
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryUsername, value: username)
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryPassword, value: password)
        // Synchronous broadcast: prevents a save/wipe race in which two
        // deferred Tasks could land out of order on the MainActor queue
        // and strand credentials on the watch after a logout-then-relogin
        // (or vice-versa).
        WatchLibraryCredentialBroadcaster.shared.broadcastSet(username: username, password: password)
    }

    static func clearCredentials() {
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
        clearToken()
        WatchLibraryCredentialBroadcaster.shared.broadcastWipe()
    }

    private static var storedPassword: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryPassword)
    }

    /// Visible to `WatchLibraryCredentialBroadcaster.republishIfCredentialed`.
    /// Returns the stored password only when we still have one — i.e. the
    /// user hasn't logged out. Never use this from app UI code; the phone
    /// surfaces never need the raw password after login.
    static func storedPasswordIfAvailable() -> String? {
        storedPassword
    }

    // MARK: - Token Management

    static var storedToken: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryToken)
    }

    static var storedTokenExpiry: Date? {
        guard let str = KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryTokenExpiry),
              let ms = Int64(str) else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    static var isTokenValid: Bool {
        guard storedToken != nil, let expiry = storedTokenExpiry else { return false }
        // 60s safety margin so a token expiring during a request round-trip
        // is treated as already-expired locally — avoids the user seeing a
        // QR that the server rejects the moment it scans.
        return Date().addingTimeInterval(60) < expiry
    }

    private static func saveToken(_ token: String, expirationMs: Int64) {
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryToken, value: token)
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryTokenExpiry, value: String(expirationMs))
    }

    static func clearToken() {
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryToken)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryTokenExpiry)
    }

    // MARK: - API Calls

    /// Login with explicit credentials and save them on success.
    @discardableResult
    static func login(username: String, password: String) async throws -> String {
        do {
            let url = URL(string: "\(baseURL)/passport/login")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                LibraryLoginRequest(username: username, password: password)
            )

            let (data, urlResponse) = try await session.data(for: request)
            try validateHTTP(urlResponse)
            let response = try JSONDecoder().decode(LibraryLoginResponse.self, from: data)

            // Treat missing `error` as success (the API omits it on the
            // happy path); only fail when an explicit non-zero code is set.
            if let apiError = response.error, apiError.code != 0 {
                let error = LibraryServiceError.loginFailed(apiError.message)
                AppLogger.captureError(error, context: ["service": "libraryLogin"])
                throw error
            }
            guard let loginData = response.data else {
                let error = LibraryServiceError.loginFailed("missing data")
                AppLogger.captureError(error, context: ["service": "libraryLogin"])
                throw error
            }

            saveCredentials(username: username, password: password)
            saveToken(loginData.token, expirationMs: loginData.expirationTimeStamp)
            return loginData.token
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryLogin"])
            throw error
        }
    }

    /// Returns a valid token, re-logging in with stored library credentials if expired.
    static func ensureToken() async throws -> String {
        if let token = storedToken, isTokenValid {
            return token
        }

        guard let username = storedUsername,
              let password = storedPassword else {
            let error = LibraryServiceError.credentialsNotFound
            AppLogger.captureError(error, context: ["service": "libraryEnsureToken"])
            throw error
        }

        return try await login(username: username, password: password)
    }

    /// Generates a QR code payload string. Auto-ensures a valid token first.
    static func generateQRCode() async throws -> String {
        do {
            let token = try await ensureToken()

            let url = URL(string: "\(baseURL)/virtual-code/generate")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                LibraryQRRequest(token: token)
            )

            let (data, urlResponse) = try await session.data(for: request)
            try validateHTTP(urlResponse)
            let response = try JSONDecoder().decode(LibraryQRResponse.self, from: data)

            if let apiError = response.error, apiError.code != 0 {
                let error = LibraryServiceError.qrGenerationFailed(apiError.message)
                AppLogger.captureError(error, context: ["service": "libraryGenerateQRCode"])
                throw error
            }
            guard let qrData = response.data else {
                let error = LibraryServiceError.qrGenerationFailed("missing data")
                AppLogger.captureError(error, context: ["service": "libraryGenerateQRCode"])
                throw error
            }

            return qrData
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryGenerateQRCode"])
            throw error
        }
    }
}
