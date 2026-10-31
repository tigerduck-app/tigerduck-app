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

enum LibraryService: AccountScoped {
    static var storedUsername: String? {
        KeychainManager.loadString(key: AppConstants.KeychainKeys.libraryUsername)
    }

    static let accountDidChange = Notification.Name("TigerDuck.libraryAccountDidChange")

    static let signInDidChange = Notification.Name("TigerDuck.librarySignInDidChange")

    @MainActor
    static func saveCredentials(username: String, password: String) {
        let accountChanged = storedUsername != username
        if accountChanged {
            AccountSession.library.moveOn()
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

    /// The library account's sign-out, which keeps the school account and School Mail.
    @MainActor
    static func clearCredentials() {
        SignOutPlan(
            session: AccountSession.library,
            stores: SignOutPlan.libraryStores,
            stopWork: { cancelStoredPasswordRetry() },
            clearRest: {
                LibraryQRCache.shared.clear()
                #if os(iOS)
                LibraryQRImageCache.shared.clear()
                WatchLibraryCredentialBroadcaster.shared.broadcastWipe()
                #endif
                NotificationCenter.default.post(name: accountDidChange, object: nil)
            }
        ).run()
    }

    static func forgetAccount(in storage: AccountStorage) {
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryUsername)
        KeychainManager.delete(key: AppConstants.KeychainKeys.libraryPassword)
        StoredPasswordBackoff.library.forget()
        clearToken()
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
        typedSignIns &+= 1
        let ticket = AccountSession.library.ticket
        let answer = try await request(username, password)
        guard AccountSession.library.isCurrent(ticket), stillCurrent() else {
            throw LibraryServiceError.credentialsNotFound
        }
        saveCredentials(username: username, password: password)
        saveToken(answer.token, expirationMs: answer.expirationTimeStamp)
        return answer.token
    }

    static func requestToken(username: String, password: String) async throws -> LibraryLoginData {
        try await LibraryRequests.requestToken(username: username, password: password, session: LibraryRequests.session)
    }

    /// The library's count in ``StoredPasswordBackoff``, which saving or clearing credentials resets.
    static var storedPasswordRefusals: (count: Int, last: Date?) {
        get { StoredPasswordBackoff.library.refusals }
        set { StoredPasswordBackoff.library.refusals = newValue }
    }

    static func storedPasswordPostIsDue(now: Date) -> Bool {
        StoredPasswordBackoff.library.postIsDue(now: now)
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
            LibraryPasswordRetry.arm(signIn: signIn, retrySleep: retrySleep)
            return false
        }
        guard signInIsDue(lastFailure: storedSignInFailedAt, now: Date()),
              await NetworkMonitor.shared.isReachable() else { return false }
        return (try? await ensureToken(signIn: signIn, retrySleep: retrySleep)) != nil
    }

    @MainActor static var storedPasswordRetry: Task<Void, Never>? { LibraryPasswordRetry.task }
    @MainActor private static var typedSignIns = 0

    @MainActor
    static func cancelStoredPasswordRetry() { LibraryPasswordRetry.cancel() }

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

        let ticket = AccountSession.library.ticket
        let typedSignInsBefore = typedSignIns
        let attempt = Task {
            let answer: LibraryLoginData
            do {
                answer = try await signIn(username, password)
            } catch {
                if AccountSession.library.isCurrent(ticket), storedPassword == password {
                    if case LibraryServiceError.loginFailed = error {
                        StoredPasswordBackoff.library.noteRefused(at: Date())
                        if typedSignIns == typedSignInsBefore {
                            LibraryPasswordRetry.arm(signIn: signIn, retrySleep: retrySleep)
                        }
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
            guard AccountSession.library.isCurrent(ticket) else { throw LibraryServiceError.credentialsNotFound }
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
            return try await LibraryRequests.requestQRCode(token: try await ensureToken(), session: LibraryRequests.session)
        } catch {
            AppLogger.captureError(error, context: ["service": "libraryGenerateQRCode"])
            throw error
        }
    }
}
