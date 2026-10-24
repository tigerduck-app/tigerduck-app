import Foundation
import os

enum WatchLibraryServiceError: LocalizedError {
    case credentialsNotFound
    case loginFailed(String)
    case qrGenerationFailed(String)
    case networkError(Error)
    case offline
    case pinMismatch

    var errorDescription: String? {
        switch self {
        case .offline:
            return String(localized: "error_network_unavailable")
        case .pinMismatch:
            return String(localized: "watch_open_phone_to_sync")
        case .credentialsNotFound:
            return String(localized: "library_sign_in_qr_prompt")
        case .loginFailed(let m):
            return String(format: String(localized: "error_library_sign_in_failed_format"), m)
        case .qrGenerationFailed:
            return String(localized: "library_qr_generate_failed")
        case .networkError(let e):
            return String(format: String(localized: "error_network_format"), e.localizedDescription)
        }
    }
}

enum WatchLibraryService {
    private static let baseURL = "https://api.lib.ntust.edu.tw/v1"
    private static let logger = WatchAppLogger.wc

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
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

    @MainActor
    static var isTokenValid: Bool {
        guard let (_, expiryMs) = WatchLibraryCredentialsStore.shared.loadToken() else {
            return false
        }
        let safeNowMs = Int64(Date().timeIntervalSince1970 * 1000) + 60_000
        return safeNowMs < expiryMs
    }

    @MainActor
    static func ensureToken() async throws -> String {
        guard let creds = WatchLibraryCredentialsStore.shared.loadCredentialsRespectingTTL() else {
            throw WatchLibraryServiceError.credentialsNotFound
        }

        if let (token, _) = WatchLibraryCredentialsStore.shared.loadToken(), isTokenValid {
            return token
        }

        return try await login(username: creds.username, password: creds.password)
    }

    typealias Send = (URLRequest, (any URLSessionTaskDelegate)?) async throws -> (Data, URLResponse)

    #if DEBUG
    /// Unit tests set this to refuse a request before it reaches the session: on watchOS a session
    /// sends a request a `URLProtocol` stub answers anyway. A unit test host refuses from launch,
    /// before the test bundle loads, so the app's own start-up sends nothing; the app leaves it nil.
    nonisolated(unsafe) static var testGuard: (@Sendable (URLRequest) throws -> Void)? = {
        guard ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil else { return nil }
        return { _ in throw URLError(.notConnectedToInternet) }
    }()
    #endif

    static func sendOnPinnedSession(
        _ request: URLRequest, _ delegate: (any URLSessionTaskDelegate)?
    ) async throws -> (Data, URLResponse) {
        #if DEBUG
        try testGuard?(request)
        #endif
        do {
            return try await session.data(for: request, delegate: delegate)
        } catch {
            throw pinMismatchOr(error, host: request.url?.host)
        }
    }

    /// The Watch shows no prompt; a refused chain asks the user to open the phone, which can
    /// accept it or fetch new pins and send them over. A refused challenge ends the request as
    /// cancelled, so an offline or timed-out request keeps its own error.
    static func pinMismatchOr(_ error: Error, host: String?, engine: TLSPinEngine = .shared) -> Error {
        guard let host, (error as? URLError)?.code == .cancelled, engine.isRefusing(host: host) else { return error }
        return WatchLibraryServiceError.pinMismatch
    }

    @MainActor
    static func generateQRCode() async throws -> String {
        try await requestQRCode(token: try await ensureToken())
    }

    static func requestQRCode(token: String, send: Send = sendOnPinnedSession) async throws -> String {
        let url = URL(string: "\(baseURL)/virtual-code/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LibraryQRRequest(token: token))

        let (data, urlResponse) = try await send(request, CredentialPostDelegate())
        try validateHTTP(urlResponse)
        let response = try JSONDecoder().decode(LibraryQRResponse.self, from: data)

        if let apiError = response.error, apiError.code != 0 {
            logger.error("QR generation failed: \(apiError.message, privacy: .private)")
            throw WatchLibraryServiceError.qrGenerationFailed(apiError.message)
        }
        guard let payload = response.data else {
            throw WatchLibraryServiceError.qrGenerationFailed("missing data")
        }
        return payload
    }

    @discardableResult
    @MainActor
    private static func login(username: String, password: String) async throws -> String {
        let loginData = try await requestToken(username: username, password: password)
        WatchLibraryCredentialsStore.shared.storeToken(
            loginData.token,
            expiryMs: loginData.expirationTimeStamp
        )
        return loginData.token
    }

    static func requestToken(
        username: String, password: String, send: Send = sendOnPinnedSession
    ) async throws -> LibraryLoginData {
        let url = URL(string: "\(baseURL)/passport/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(
            LibraryLoginRequest(username: username, password: password)
        )

        let (data, urlResponse) = try await send(request, CredentialPostDelegate())
        try validateHTTP(urlResponse)
        let response = try JSONDecoder().decode(LibraryLoginResponse.self, from: data)

        if let apiError = response.error, apiError.code != 0 {
            logger.error("login failed: \(apiError.message, privacy: .private)")
            throw WatchLibraryServiceError.loginFailed(apiError.message)
        }
        guard let loginData = response.data else {
            throw WatchLibraryServiceError.loginFailed("missing data")
        }
        return loginData
    }
}
