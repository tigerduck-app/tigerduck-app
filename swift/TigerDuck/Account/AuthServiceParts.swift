import Foundation
#if os(iOS)
import UserNotifications
#endif

/// The sign-in steps and clocks `AuthService` runs on; tests pass their own.
struct AuthServiceDependencies {
    let keychainHasCredentials: () -> Bool
    let moodleTokens: MoodleTokenService
    let schoolSignIn: (_ studentId: String, _ password: String) async throws -> Bool
    let schoolSessionIsLive: () async -> Bool
    let renewSchoolSignIn: (
        _ studentId: String, _ password: String, _ isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool
    let retrySchoolSignIn: (
        _ studentId: String, _ password: String, _ isCurrent: @escaping @MainActor () -> Bool, _ mayPost: () -> Bool
    ) async throws -> Bool
    let endSchoolSession: @MainActor (_ departingStudentId: String?) -> Void
    let now: () -> Date
    let retrySleep: @Sendable (Duration) async -> Void
}

/// What the sign-in screens show: a sign-in or a renewal under way, and the last error of each.
struct AuthStatus {
    var isReauthenticating = false
    var reauthErrorMessage: String?
    var isLoggingIn = false
    var loginError: String?
}

/// Whether the keychain held the credentials when last read. `revision` moves on each change, so
/// what reads the stored account reads it again.
struct CredentialMirror {
    var revision = 0
    var lastKnown: Bool?
}

/// What the composition root plugs into `AuthService`.
struct AuthServiceHooks {
    var authTokenManager: AuthTokenManager?
    var onV3SignedIn: (() -> Void)?
    var signOutStoredAccount: (() async -> Void)?
    #if os(iOS)
    var accountNotifications: any DeliveredNotificationCenter = UNUserNotificationCenter.current()
    #endif
    var beginSignOutBackgroundTask: @Sendable () async -> @Sendable () async -> Void = {
        await AuthTokenManager.beginBackgroundTask(named: "Sign-out")
    }
    var forgetPages: @MainActor () async -> Void = {}
}

/// The sign-out calls under way, which the next sign-out and sign-in wait for, and the launch's
/// retry of an unregister an earlier sign-out kept.
struct SignOutTasks {
    var calls: Task<Void, Never>?
    var departingUnregisterRetry: Task<Void, Never>?
}

/// The school sign-in through NTUST SSO for the course selection service, whose session the
/// school data pages share.
enum SchoolSignIn {
    private static let ssoServiceURL = URL.knownGood("https://courseselection.ntust.edu.tw/")

    static func signIn(studentId: String, password: String) async throws -> Bool {
        try await SSOLoginService.ensureServiceLogin(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            isCurrent: AccountSession.school.currentCheck(),
            interactive: true
        )
    }

    static func renew(
        studentId: String, password: String, isCurrent: @escaping @MainActor () -> Bool
    ) async throws -> Bool {
        try await SSOLoginService.ensureServiceLogin(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            isCurrent: isCurrent
        )
    }

    static func retry(
        studentId: String, password: String, isCurrent: @escaping @MainActor () -> Bool, mayPost: () -> Bool
    ) async throws -> Bool {
        try await SSOLoginService.signInAgain(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            isCurrent: isCurrent,
            mayPost: mayPost
        )
    }
}
