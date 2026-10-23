import Defaults
import Foundation

enum LibraryServiceError: LocalizedError {
    case credentialsNotFound
    case loginFailed(String)
    case qrGenerationFailed(String)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .credentialsNotFound: String(localized: "error_library_credentials_not_found")
        case .loginFailed(let msg): String(format: String(localized: "error_library_sign_in_failed_format"), msg)
        case .qrGenerationFailed(let msg): String(format: String(localized: "error_qr_generation_failed_format"), msg)
        case .networkError(let e): String(format: String(localized: "error_network_format"), e.localizedDescription)
        }
    }
}

enum LibraryService {
    private static let baseURL = "https://api.lib.ntust.edu.tw/v1"

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

    static var storedUsername: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryUsername)
    }

    @MainActor private(set) static var loginGeneration: Int = 0

    static let accountDidChange = Notification.Name("TigerDuck.libraryAccountDidChange")

    static let signInDidChange = Notification.Name("TigerDuck.librarySignInDidChange")

    @MainActor
    static func saveCredentials(username: String, password: String) {
        let accountChanged = storedUsername != username
        if accountChanged {
            loginGeneration &+= 1
        }
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryUsername, value: username)
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryPassword, value: password)
        storedPasswordRefusals = (0, nil)
        cancelStoredPasswordRetry()
        if accountChanged {
            LibraryQRCache.shared.clear()
            #if os(iOS)
            LibraryQRImageCache.shared.clear()
            #endif
            NotificationCenter.default.post(name: accountDidChange, object: nil)
        }
        #if os(iOS)
        WatchLibraryCredentialBroadcaster.shared.broadcastSet(username: username, password: password)
        #endif
    }

    @MainActor
    static func clearCredentials() {
        loginGeneration &+= 1
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
        storedPasswordRefusals = (0, nil)
        cancelStoredPasswordRetry()
        clearToken()
        LibraryQRCache.shared.clear()
        #if os(iOS)
        LibraryQRImageCache.shared.clear()
        WatchLibraryCredentialBroadcaster.shared.broadcastWipe()
        #endif
        NotificationCenter.default.post(name: accountDidChange, object: nil)
    }

    private static var storedPassword: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryPassword)
    }

    static func storedPasswordIfAvailable() -> String? {
        storedPasswordRefusals.count > 0 ? nil : storedPassword
    }

    /// The library account stays through a school sign-out. Only a sign-in form that offered the
    /// departing school account's student ID, shown while no library account is stored, empties.
    @MainActor
    static func schoolAccountDidSignOut() {
        if storedUsername == nil, !hasAccount { NotificationCenter.default.post(name: accountDidChange, object: nil) }
    }

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

    @discardableResult
    static func login(
        username: String,
        password: String,
        stillCurrent: @MainActor () -> Bool = { true },
        request: @MainActor (String, String) async throws -> LibraryLoginData = requestToken(username:password:)
    ) async throws -> String {
        cancelStoredPasswordRetry()
        let generation = loginGeneration
        let answer = try await request(username, password)
        guard loginGeneration == generation, stillCurrent() else { throw LibraryServiceError.credentialsNotFound }
        saveCredentials(username: username, password: password)
        saveToken(answer.token, expirationMs: answer.expirationTimeStamp)
        return answer.token
    }

    static func requestToken(username: String, password: String) async throws -> LibraryLoginData {
        try await requestToken(username: username, password: password, session: session)
    }

    static func requestToken(username: String, password: String, session: URLSession) async throws -> LibraryLoginData {
        do {
            let url = URL(string: "\(baseURL)/passport/login")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                LibraryLoginRequest(username: username, password: password)
            )

            let (data, urlResponse) = try await session.data(for: request, delegate: CredentialPostDelegate())
            return try loginAnswer(urlResponse, data: data)
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryLogin"])
            throw error
        }
    }

    static func loginAnswer(_ response: URLResponse, data: Data) throws -> LibraryLoginData {
        if let status = (response as? HTTPURLResponse)?.statusCode, (400..<500).contains(status) {
            throw LibraryServiceError.loginFailed("HTTP \(status)")
        }
        try validateHTTP(response)
        let decoded = try JSONDecoder().decode(LibraryLoginResponse.self, from: data)
        // Treat missing `error` as success (the API omits it on the
        // happy path); only fail when an explicit non-zero code is set.
        if let apiError = decoded.error, apiError.code != 0 {
            throw LibraryServiceError.loginFailed(apiError.message)
        }
        guard let loginData = decoded.data else {
            throw LibraryServiceError.loginFailed("missing data")
        }
        return loginData
    }

    /// Each refusal counts toward the library account's lockout, so after one an automatic sign-in
    /// waits as the school's does (``SSOLoginService/storedPasswordRetryDelay(afterRefusals:)``).
    /// A sign-in the user types is never held back, and saving or clearing credentials resets it.
    static var storedPasswordRefusals: (count: Int, last: Date?) {
        get { (Defaults[.libraryStoredPasswordRefusals], Defaults[.libraryStoredPasswordRefusedAt]) }
        set {
            Defaults[.libraryStoredPasswordRefusals] = newValue.count
            Defaults[.libraryStoredPasswordRefusedAt] = newValue.last
        }
    }

    static func storedPasswordPostIsDue(now: Date) -> Bool {
        let refusals = storedPasswordRefusals
        guard let retryAt = SSOLoginService.storedPasswordRetryAt(
            refusals: refusals.count, lastRefusal: refusals.last, now: now
        ) else { return true }
        return retryAt <= now
    }

    @MainActor private static var pendingSignIns: [String: Task<String, Error>] = [:]
    @MainActor private static var storedSignInFailedAt: Date?
    nonisolated static let signInPause: TimeInterval = 5 * 60

    nonisolated static func signInIsDue(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        let age = now.timeIntervalSince(lastFailure)
        return age >= signInPause || age < 0
    }

    @MainActor static var canSignInWithStoredCredentials: Bool {
        storedUsername != nil && storedPassword != nil && storedPasswordRefusals.count == 0
    }

    @MainActor static var hasAccount: Bool {
        isTokenValid || canSignInWithStoredCredentials
    }

    @MainActor @discardableResult
    static func signInIfCredentialed(
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData = requestToken(username:password:),
        retrySleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async -> Bool {
        guard !isTokenValid, storedUsername != nil, storedPassword != nil else { return false }
        guard storedPasswordPostIsDue(now: Date()) else {
            armStoredPasswordRetry(signIn: signIn, retrySleep: retrySleep)
            return false
        }
        guard signInIsDue(lastFailure: storedSignInFailedAt, now: Date()),
              await NetworkMonitor.shared.isReachable() else { return false }
        return (try? await ensureToken(signIn: signIn, retrySleep: retrySleep)) != nil
    }

    @MainActor private(set) static var storedPasswordRetry: Task<Void, Never>?
    @MainActor private static var storedPasswordRetryMisses = 0

    /// Posts the stored password again once its wait ends, as `AuthService` does for the school,
    /// so a page left on the sign-in form signs in without a return to the app.
    @MainActor
    private static func armStoredPasswordRetry(
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData,
        retrySleep: @escaping @Sendable (Duration) async -> Void
    ) {
        storedPasswordRetryMisses = 0
        let now = Date()
        let refusals = storedPasswordRefusals
        guard let retryAt = SSOLoginService.storedPasswordRetryAt(
            refusals: refusals.count, lastRefusal: refusals.last, now: now
        ) else { return cancelStoredPasswordRetry() }
        startStoredPasswordRetry(after: max(0, retryAt.timeIntervalSince(now)), signIn: signIn, retrySleep: retrySleep)
    }

    @MainActor
    private static func startStoredPasswordRetry(
        after wait: TimeInterval,
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData,
        retrySleep: @escaping @Sendable (Duration) async -> Void
    ) {
        cancelStoredPasswordRetry()
        let generation = loginGeneration
        storedPasswordRetry = Task {
            await retrySleep(.seconds(wait))
            guard !Task.isCancelled, loginGeneration == generation else { return }
            storedPasswordRetry = nil
            guard storedPasswordPostIsDue(now: Date()) else {
                return armStoredPasswordRetry(signIn: signIn, retrySleep: retrySleep)
            }
            let refusals = storedPasswordRefusals.count
            guard (try? await ensureToken(signIn: signIn, retrySleep: retrySleep)) == nil,
                  loginGeneration == generation, refusals > 0, storedPasswordRefusals.count == refusals,
                  storedPasswordRetry == nil else { return }
            storedPasswordRetryMisses += 1
            startStoredPasswordRetry(
                after: SSOLoginService.storedPasswordRetryDelay(afterRefusals: refusals + storedPasswordRetryMisses),
                signIn: signIn, retrySleep: retrySleep
            )
        }
    }

    @MainActor
    static func cancelStoredPasswordRetry() {
        storedPasswordRetry?.cancel()
        storedPasswordRetry = nil
    }

    @MainActor
    static func ensureToken(
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData = requestToken(username:password:),
        retrySleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) async throws -> String {
        if let token = storedToken, isTokenValid {
            return token
        }

        guard let username = storedUsername,
              let password = storedPassword,
              storedPasswordPostIsDue(now: Date()) else {
            let error = LibraryServiceError.credentialsNotFound
            AppLogger.captureError(error, context: ["service": "libraryEnsureToken"])
            throw error
        }
        if let pending = pendingSignIns[username] {
            return try await pending.value
        }

        let generation = loginGeneration
        let attempt = Task {
            let answer: LibraryLoginData
            do {
                answer = try await signIn(username, password)
            } catch {
                if loginGeneration == generation, storedPassword == password {
                    if case LibraryServiceError.loginFailed = error {
                        storedPasswordRefusals = (storedPasswordRefusals.count + 1, Date())
                        armStoredPasswordRetry(signIn: signIn, retrySleep: retrySleep)
                        #if os(iOS)
                        WatchLibraryCredentialBroadcaster.shared.broadcastWipe()
                        #endif
                        NotificationCenter.default.post(name: signInDidChange, object: nil)
                    } else {
                        storedSignInFailedAt = Date()
                    }
                }
                throw error
            }
            guard loginGeneration == generation else { throw LibraryServiceError.credentialsNotFound }
            saveToken(answer.token, expirationMs: answer.expirationTimeStamp)
            storedSignInFailedAt = nil
            if storedPasswordRefusals.count > 0, storedPassword == password {
                storedPasswordRefusals = (0, nil)
                #if os(iOS)
                WatchLibraryCredentialBroadcaster.shared.broadcastSet(username: username, password: password)
                #endif
            }
            NotificationCenter.default.post(name: signInDidChange, object: nil)
            return answer.token
        }
        pendingSignIns[username] = attempt
        defer { pendingSignIns[username] = nil }
        return try await attempt.value
    }

    static func generateQRCode() async throws -> String {
        do {
            return try await requestQRCode(token: try await ensureToken(), session: session)
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryGenerateQRCode"])
            throw error
        }
    }

    static func requestQRCode(token: String, session: URLSession) async throws -> String {
        let url = URL(string: "\(baseURL)/virtual-code/generate")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(LibraryQRRequest(token: token))

        let (data, urlResponse) = try await session.data(for: request, delegate: CredentialPostDelegate())
        try validateHTTP(urlResponse)
        let response = try JSONDecoder().decode(LibraryQRResponse.self, from: data)

        if let apiError = response.error, apiError.code != 0 {
            throw LibraryServiceError.qrGenerationFailed(apiError.message)
        }
        guard let qrData = response.data else { throw LibraryServiceError.qrGenerationFailed("missing data") }
        return qrData
    }
}
