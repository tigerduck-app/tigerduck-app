import Foundation
import os

enum WatchLibraryServiceError: LocalizedError {
    case credentialsNotFound
    case loginFailed(String)
    case qrGenerationFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound:
            return String(localized: "watch_library_signin_prompt")
        case .loginFailed(let m):
            return String(format: String(localized: "error_library_login_failed_format"), m)
        case .qrGenerationFailed(let m):
            return String(format: String(localized: "error_qr_generation_failed_format"), m)
        case .networkError(let e):
            return String(format: String(localized: "error_network_format"), e.localizedDescription)
        }
    }
}

/// Watch-side mirror of phone `LibraryService`. Reads credentials from
/// `WatchLibraryCredentialsStore` (the only authority for what the
/// watch knows). Caches the bearer token in the watch keychain via
/// the store; refreshes by hitting `/passport/login` directly when
/// expired. Same URLSession hygiene as the phone — ephemeral session,
/// 15s/30s timeouts, no caching.
enum WatchLibraryService {
    private static let baseURL = "https://api.lib.ntust.edu.tw/v1"
    private static let logger = WatchAppLogger.wc

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()

    private static func validateHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw WatchLibraryServiceError.networkError(URLError(.badServerResponse))
        }
        guard (200..<300).contains(http.statusCode) else {
            let underlying = URLError(
                .badServerResponse,
                userInfo: [
                    NSLocalizedDescriptionKey: "HTTP \(http.statusCode)",
                    "statusCode": http.statusCode,
                ]
            )
            throw WatchLibraryServiceError.networkError(underlying)
        }
    }

    // MARK: - Token validity

    /// True when a non-empty token is cached and its expiry is at least
    /// 60s away. Same 60s safety margin as the phone — if the token is
    /// about to expire mid-request, we proactively log in again so the
    /// QR the user sees isn't rejected on first scan.
    @MainActor
    static var isTokenValid: Bool {
        guard let (_, expiryMs) = WatchLibraryCredentialsStore.shared.loadToken() else {
            return false
        }
        let safeNowMs = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        return safeNowMs < expiryMs
    }

    // MARK: - Public API

    /// Returns a valid token, logging in with stored credentials if cached
    /// token is missing/expired. Throws `.credentialsNotFound` if the
    /// watch has no credentials (or they are past TTL).
    @MainActor
    static func ensureToken() async throws -> String {
        if let (token, _) = WatchLibraryCredentialsStore.shared.loadToken(), isTokenValid {
            return token
        }

        guard let creds = WatchLibraryCredentialsStore.shared.loadCredentialsRespectingTTL() else {
            throw WatchLibraryServiceError.credentialsNotFound
        }

        return try await login(username: creds.username, password: creds.password)
    }

    @MainActor
    static func generateQRCode() async throws -> String {
        let token = try await ensureToken()

        let url = URL(string: "\(baseURL)/virtual-code/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LibraryQRRequest(token: token))

        let (data, urlResponse) = try await session.data(for: request)
        try validateHTTP(urlResponse)
        let response = try JSONDecoder().decode(LibraryQRResponse.self, from: data)

        if let apiError = response.error, apiError.code != 0 {
            logger.error("QR generation failed: \(apiError.message, privacy: .public)")
            throw WatchLibraryServiceError.qrGenerationFailed(apiError.message)
        }
        guard let payload = response.data else {
            throw WatchLibraryServiceError.qrGenerationFailed("missing data")
        }
        return payload
    }

    // MARK: - Internal

    @discardableResult
    @MainActor
    private static func login(username: String, password: String) async throws -> String {
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

        if let apiError = response.error, apiError.code != 0 {
            logger.error("login failed: \(apiError.message, privacy: .public)")
            throw WatchLibraryServiceError.loginFailed(apiError.message)
        }
        guard let loginData = response.data else {
            throw WatchLibraryServiceError.loginFailed("missing data")
        }

        WatchLibraryCredentialsStore.shared.storeToken(
            loginData.token,
            expiryMs: loginData.expirationTimeStamp
        )
        return loginData.token
    }
}
