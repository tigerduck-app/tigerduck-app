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
        // SPKI pin against the api.lib.ntust.edu.tw set. Library
        // bearer tokens are exchanged here and gate every QR-generate
        // call, so hostile-network MITM is the relevant risk to close.
        return URLSession(
            configuration: config,
            delegate: TLSPinningDelegate.shared,
            delegateQueue: nil,
        )
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

    /// Bumped whenever the stored library identity changes: a logout, or a different
    /// account signing in. Callers read it before their request and compare it before
    /// storing anything. ``AuthService/loginGeneration`` guards the NTUST side the same way.
    ///
    /// The QR path is untracked async work: `generateQRCode()` is a network round trip,
    /// and the rasterise after it hops off the main actor. Without the check, a logout in
    /// that window lets the previous user's code land in the process-wide caches and on
    /// screen, which `swift/TigerDuck/AGENTS.md` forbids.
    @MainActor private(set) static var loginGeneration: Int = 0

    /// Posted on the main actor whenever `loginGeneration` moves — a sign-out,
    /// or a different account signing in. The generation only stops work that
    /// is still in flight; a code that already landed stays on whatever screen
    /// shows it until that screen next refreshes, so a screen that is up when
    /// the account changes listens for this and drops it at once.
    static let accountDidChange = Notification.Name("TigerDuck.libraryAccountDidChange")

    /// Posted on the main actor when a sign-in with the stored credentials stores a new token, or
    /// the library refuses them, which signs the account out. No screen asked for either, so
    /// `AppState.isLibraryLoggedIn` reads the state again on this.
    static let signInDidChange = Notification.Name("TigerDuck.librarySignInDidChange")

    /// `@MainActor`-isolated so the broadcaster call below is an in-actor
    /// sync call (no deferred Task). This preserves serialization — a
    /// save followed by a clear runs broadcastSet → broadcastWipe in
    /// program order — and keeps the calling boundary actor-safe under
    /// strict concurrency.
    @MainActor
    static func saveCredentials(username: String, password: String) {
        // Only a real account change invalidates work in flight. A save for the same account,
        // such as a sign-in with its new password, leaves that account's QR request standing.
        let accountChanged = storedUsername != username
        if accountChanged {
            loginGeneration &+= 1
        }
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryUsername, value: username)
        KeychainManager.saveString(key: AppConstants.KeychainKeys.libraryPassword, value: password)
        storedPasswordRejected = false
        if accountChanged {
            // A code cached for the previous account still scans as theirs, and
            // `LibraryViewModel.startQRRefreshCycle` reuses a cached code with time left, so
            // switching accounts without a sign-out would put the old code back on screen.
            LibraryQRCache.shared.clear()
            #if os(iOS)
            LibraryQRImageCache.shared.clear()
            #endif
            // After the save, so a listener that re-reads the account sees the new one.
            NotificationCenter.default.post(name: accountDidChange, object: nil)
        }
        // iOS-only: macOS has no paired watch surface and the broadcaster
        // (WatchConnectivity) isn't in the Mac target. Mirrors the
        // existing iOS-gating pattern used elsewhere in the watch path.
        #if os(iOS)
        WatchLibraryCredentialBroadcaster.shared.broadcastSet(username: username, password: password)
        #endif
    }

    /// See `saveCredentials` for the `@MainActor` rationale.
    @MainActor
    static func clearCredentials() {
        // Before the deletes, so anything that reads it from here on already
        // sees its captured generation as stale.
        loginGeneration &+= 1
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
        storedPasswordRejected = false
        clearToken()
        LibraryQRCache.shared.clear()
        #if os(iOS)
        // The rendered QR image is credential-derived too and must not outlive the session in
        // a process-wide singleton. iOS-only: the cache holds a `UIImage` and, like the rest of
        // the Library UI, is not on the Mac allowlist `INCLUDED_SOURCE_FILE_NAMES[sdk=macosx*]`.
        LibraryQRImageCache.shared.clear()
        WatchLibraryCredentialBroadcaster.shared.broadcastWipe()
        #endif
        // Last, once everything the account owned is gone.
        NotificationCenter.default.post(name: accountDidChange, object: nil)
    }

    private static var storedPassword: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryPassword)
    }

    /// Visible to `WatchLibraryCredentialBroadcaster.republishIfCredentialed`.
    /// Returns the stored password only while the user is signed in and the
    /// library has not refused it, which the Watch would otherwise send again.
    /// Never use this from app UI code; the phone surfaces never need the raw
    /// password after login.
    static func storedPasswordIfAvailable() -> String? {
        storedPasswordRejected ? nil : storedPassword
    }

    /// Signs out of the library when its account is the school account signing out, so whoever
    /// signs in next does not keep it. A library account of another ID stays. Returns whether it
    /// signed out.
    @MainActor
    static func clearCredentials(ifSchoolAccount studentId: String) -> Bool {
        guard let username = storedUsername, username.caseInsensitiveCompare(studentId) == .orderedSame else {
            return false
        }
        clearCredentials()
        return true
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

    /// Signs in with the given credentials, and saves them and the token on success.
    /// `stillCurrent` is asked when the answer arrives: false keeps nothing, for a caller whose
    /// own account, such as the school one it signs in with, changed meanwhile.
    @discardableResult
    static func login(
        username: String,
        password: String,
        stillCurrent: @MainActor () -> Bool = { true },
        request: @MainActor (String, String) async throws -> LibraryLoginData = requestToken(username:password:)
    ) async throws -> String {
        let generation = loginGeneration
        let answer = try await request(username, password)
        // Signed out, or another account signed in, while the request was out.
        guard loginGeneration == generation, stillCurrent() else { throw LibraryServiceError.credentialsNotFound }
        saveCredentials(username: username, password: password)
        saveToken(answer.token, expirationMs: answer.expirationTimeStamp)
        return answer.token
    }

    /// Sends the credentials and returns the library's answer, storing nothing.
    static func requestToken(username: String, password: String) async throws -> LibraryLoginData {
        do {
            let url = URL(string: "\(baseURL)/passport/login")!
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(
                LibraryLoginRequest(username: username, password: password)
            )

            let (data, urlResponse) = try await session.data(for: request)
            return try loginAnswer(urlResponse, data: data)
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryLogin"])
            throw error
        }
    }

    /// Reads the library's answer to a sign-in. A 4xx is a refusal like a wrong password: which
    /// status a wrong password gets is unchecked, and a refusal stops the automatic sign-ins.
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

    /// The library refused the stored password in a sign-in the user did not type. Each refusal
    /// counts toward the account's lockout, so the stored password is not sent again until a
    /// sign-in saves credentials that work.
    static var storedPasswordRejected: Bool {
        get { Defaults[.libraryStoredPasswordRejected] }
        set { Defaults[.libraryStoredPasswordRejected] = newValue }
    }
    /// Each account's sign-in under way, which another caller for that account waits for
    /// instead of starting a second one.
    @MainActor private static var pendingSignIns: [String: Task<String, Error>] = [:]
    /// When a sign-in with the stored credentials last failed short of a refusal, with no answer
    /// or a server error. Returns to the app wait ``signInPause`` before sending them again.
    @MainActor private static var storedSignInFailedAt: Date?
    nonisolated static let signInPause: TimeInterval = 5 * 60

    /// Whether a return to the app may sign in again. Measured from the failure, so a clock set
    /// back does not stretch the pause.
    nonisolated static func signInIsDue(lastFailure: Date?, now: Date) -> Bool {
        guard let lastFailure else { return true }
        let age = now.timeIntervalSince(lastFailure)
        return age >= signInPause || age < 0
    }

    /// Whether `ensureToken()` can sign in again by itself once the token runs out.
    @MainActor static var canSignInWithStoredCredentials: Bool {
        storedUsername != nil && storedPassword != nil && !storedPasswordRejected
    }

    /// Whether a library account is signed in, as the Library page, Settings and the flip count
    /// it: its token is live, or its stored credentials sign in again behind the code.
    @MainActor static var hasAccount: Bool {
        isTokenValid || canSignInWithStoredCredentials
    }

    /// Whether ``hasAccount`` holds for a library account of another student ID than `studentId`.
    /// A school sign-in keeps such an account, as ``clearCredentials(ifSchoolAccount:)`` does.
    @MainActor static func hasAccount(otherThan studentId: String) -> Bool {
        guard hasAccount, let username = storedUsername else { return false }
        return username.caseInsensitiveCompare(studentId) != .orderedSame
    }

    /// Signs in with the stored credentials when there is no live token, so the Library page
    /// shows its code at once. Called at launch and on each return to the app. Returns whether
    /// it signed in.
    @MainActor @discardableResult
    static func signInIfCredentialed(
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData = requestToken(username:password:)
    ) async -> Bool {
        guard !isTokenValid, canSignInWithStoredCredentials,
              signInIsDue(lastFailure: storedSignInFailedAt, now: Date()),
              await NetworkMonitor.shared.isReachable() else { return false }
        return (try? await ensureToken(signIn: signIn)) != nil
    }

    /// Returns a valid token, signing in again with the stored credentials once it runs out.
    /// That sign-in keeps only the token, and only while the same account is still stored.
    @MainActor
    static func ensureToken(
        signIn: @escaping @MainActor (String, String) async throws -> LibraryLoginData = requestToken(username:password:)
    ) async throws -> String {
        if let token = storedToken, isTokenValid {
            return token
        }

        guard canSignInWithStoredCredentials,
              let username = storedUsername,
              let password = storedPassword else {
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
                // A failure says something only about the credentials still stored.
                if loginGeneration == generation, storedPassword == password {
                    if case LibraryServiceError.loginFailed = error {
                        storedPasswordRejected = true
                        #if os(iOS)
                        // The Watch would sign in with its own copy; a working sign-in sends it again.
                        WatchLibraryCredentialBroadcaster.shared.broadcastWipe()
                        #endif
                        NotificationCenter.default.post(name: signInDidChange, object: nil)
                    } else {
                        storedSignInFailedAt = Date()
                    }
                }
                throw error
            }
            // Signed out, or another account signed in, while the request was out.
            guard loginGeneration == generation else { throw LibraryServiceError.credentialsNotFound }
            saveToken(answer.token, expirationMs: answer.expirationTimeStamp)
            storedSignInFailedAt = nil
            NotificationCenter.default.post(name: signInDidChange, object: nil)
            return answer.token
        }
        pendingSignIns[username] = attempt
        defer { pendingSignIns[username] = nil }
        return try await attempt.value
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
