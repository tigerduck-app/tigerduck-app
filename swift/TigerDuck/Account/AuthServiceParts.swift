import Foundation
#if os(iOS)
import UserNotifications
#endif

struct AuthServiceDependencies {
    let keychainHasCredentials: () -> Bool
    let moodleTokens: MoodleTokenService
    let schoolSignIn: (_ studentId: String, _ password: String, _ signIn: SignIn) async throws -> Bool
    let schoolSessionIsLive: (_ signIn: SignIn) async -> Bool
    let renewSchoolSignIn: (_ studentId: String, _ password: String, _ signIn: SignIn) async throws -> Bool
    let retrySchoolSignIn: (
        _ studentId: String, _ password: String, _ signIn: SignIn, _ mayPost: () -> Bool
    ) async throws -> Bool
    let endSchoolSession: @MainActor (_ departingStudentId: String?) -> Void
    let now: () -> Date
    let retrySleep: @Sendable (Duration) async -> Void
}

struct AuthStatus {
    var isReauthenticating = false
    var reauthErrorMessage: String?
    var isLoggingIn = false
    var loginError: String?
}

struct CredentialMirror {
    var revision = 0
    var lastKnown: Bool?
}

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

struct SignOutTasks {
    var calls: Task<Void, Never>?
    var departingUnregisterRetry: Task<Void, Never>?
}

enum SchoolSignIn {
    private static let ssoServiceURL = URL.knownGood("https://courseselection.ntust.edu.tw/")

    static func signIn(studentId: String, password: String, for signIn: SignIn) async throws -> Bool {
        try await SSOLoginService.ensureServiceLogin(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            for: signIn,
            interactive: true
        )
    }

    static func renew(studentId: String, password: String, for signIn: SignIn) async throws -> Bool {
        try await SSOLoginService.ensureServiceLogin(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            for: signIn
        )
    }

    static func retry(
        studentId: String, password: String, for signIn: SignIn, mayPost: () -> Bool
    ) async throws -> Bool {
        try await SSOLoginService.signInAgain(
            session: NTUSTSessionManager.shared.session,
            serviceURL: ssoServiceURL,
            studentId: studentId,
            password: password,
            for: signIn,
            mayPost: mayPost
        )
    }
}
