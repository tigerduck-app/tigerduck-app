#if os(iOS)
import Foundation
import Observation

@MainActor
@Observable
final class MailAccountManager {
    enum LoginError: Equatable, Sendable {
        case credentials, network, certificate, busy, generic

        init(_ error: any Error) {
            switch error as? MailClientError {
            case .authenticationFailed: self = .credentials
            case .unreachable: self = .network
            case .certificateRejected: self = .certificate
            case .serverBusy: self = .busy
            default: self = .generic
            }
        }

        var message: String {
            switch self {
            case .credentials: String(localized: "school_mail_error_auth")
            case .network: String(localized: "school_mail_error_network")
            case .certificate: String(localized: "school_mail_error_certificate")
            case .busy: String(localized: "school_mail_error_busy")
            case .generic: String(localized: "school_mail_error_generic")
            }
        }
    }

    static let shared = MailAccountManager(signOutEvents: .default, session: .mail)

    static let didSignOut = Notification.Name("SchoolMail.didSignOut")

    private(set) var studentID: String?
    private var signInStatus = MailLoginStatus()
    private var auth: MailAuthFailure
    private var settings: MailAccountSettings
    @ObservationIgnored private(set) var lastRejectedPassword: String?
    @ObservationIgnored var listeners: MailAccountListeners
    @ObservationIgnored let prefs: any MailPreferences
    @ObservationIgnored private let signIn: MailSignInParts
    @ObservationIgnored let cacheWipe: MailCacheWipe
    @ObservationIgnored let session: AccountSession

    var isLoggingIn: Bool { signInStatus.isLoggingIn }
    var loginError: LoginError? { signInStatus.error }

    private(set) var authFailed: Bool {
        get { auth.isFailed }
        set { if newValue != auth.isFailed { auth = MailAuthFailure(isFailed: newValue) } }
    }
    var authBannerDismissed: Bool {
        get { auth.bannerDismissed }
        set { auth.bannerDismissed = newValue }
    }
    var showsAuthFailedBanner: Bool { authFailed && !authBannerDismissed }

    var displayName: String? { settings.displayName }
    var notificationsEnabled: Bool { settings.notificationsEnabled }
    var muteSettings: MailMuteSettings { settings.muteSettings }

    func setDisplayName(_ name: String?, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        settings.displayName = name
        prefs.change(for: signIn) { $0.displayName = name?.mailNonEmpty }
    }

    func setNotificationsEnabled(_ enabled: Bool, for signIn: SignIn) {
        guard signIn.isCurrent, enabled != settings.notificationsEnabled else { return }
        settings.notificationsEnabled = enabled
        prefs.change(for: signIn) { $0.notificationsEnabled = enabled }
        guard isLoggedIn else { return }
        if enabled { listeners.notificationsEnabled?() } else { listeners.notificationsDisabled?() }
    }

    func setMuteSettings(_ mute: MailMuteSettings, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        settings.muteSettings = mute
        prefs.change(for: signIn) { $0.muteSettings = mute }
    }

    var isLoggedIn: Bool { studentID != nil }
    var address: String? { studentID.map(MailConstants.address(forStudentID:)) }
    var isDemo: Bool { prefs.demoActive }
    var cache: MailCache { cacheWipe.cache }
    var pendingCacheClear: Task<Void, Never>? { cacheWipe.pending }

    init(
        prefs: any MailPreferences = MailSettingsStore.shared,
        credentials: MailCredentialStore = MailCredentialStore(),
        cache: MailCache = .shared,
        isDemoLogin: @escaping (String, String) -> Bool = { MailDemoFixture.shared?.matches(studentID: $0, password: $1) ?? false },
        makeClient: @escaping (Bool) -> any MailClient = { MailClientFactory.make(demo: $0) },
        clearCache: (@Sendable () async -> Void)? = nil,
        signOutEvents: NotificationCenter = NotificationCenter(),
        session: AccountSession = AccountSession()
    ) {
        self.session = session
        self.prefs = prefs
        listeners = MailAccountListeners(signOutEvents: signOutEvents)
        signIn = MailSignInParts(credentials: credentials, isDemoLogin: isDemoLogin, makeClient: makeClient)
        cacheWipe = MailCacheWipe(cache: cache, clear: clearCache)
        studentID = prefs.studentID
        auth = MailAuthFailure(isFailed: prefs.authFailed)
        settings = MailAccountSettings(displayName: prefs.displayName, notificationsEnabled: prefs.notificationsEnabled,
                                       muteSettings: prefs.muteSettings)
    }

    func login(studentID rawID: String, password: String) async {
        let id = Self.normalizedUsername(rawID)
        guard !id.isEmpty, !password.isEmpty, !isLoggingIn else { return }
        signInStatus.isLoggingIn = true
        signInStatus.error = nil
        defer { signInStatus.isLoggingIn = false }
        guard let client = await session.withSignIn({ await signInClient(id, password, during: $0) }) else { return }
        let signedIn = session.endSignIn()

        lastRejectedPassword = nil
        prefs.change(for: signedIn) {
            $0.studentID = id
            $0.demoActive = client.demo
            $0.authFailed = false
        }
        await establishBaseline(client: client.client, for: signedIn)
        if prefs.displayName == nil {
            let discovered = await discoverDisplayName(client: client.client, address: MailConstants.address(forStudentID: id))
            setDisplayName(discovered, for: signedIn)
        }
        await client.client.logout()

        guard signedIn.isCurrent else { return }
        authFailed = false
        studentID = id
        listeners.signedIn?()
    }

    private func signInClient(
        _ id: String, _ password: String, during signedOut: SignIn
    ) async -> (client: any MailClient, demo: Bool)? {
        await cacheWipe.pending?.value
        guard signedOut.isCurrent else { return nil }
        cacheWipe.forgetFinished()

        let demo = signIn.isDemoLogin(id, password)
        let client = signIn.makeClient(demo)
        do {
            try await client.login(studentID: id, password: password)
            guard signedOut.isCurrent else {
                await client.logout()
                return nil
            }
            try signIn.credentials.savePassword(password, for: signedOut)
        } catch {
            await client.logout()
            let failure = LoginError(error)
            if failure == .credentials { lastRejectedPassword = password }
            signInStatus.error = failure
            return nil
        }
        return (client, demo)
    }

    // RFC 5321 §2.3.11 lets a server treat an address's local part as case-sensitive.
    static func normalizedUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") ? trimmed : trimmed.uppercased()
    }

    func clearLoginError() {
        signInStatus.error = nil
    }

    func openSession() async throws -> any MailClient {
        guard !authFailed else { throw MailClientError.authenticationFailed }
        guard let id = prefs.studentID, let password = signIn.credentials.password() else {
            throw MailClientError.protocolError("credentials unavailable")
        }
        let client = signIn.makeClient(prefs.demoActive)
        return try await session.withSignIn { signedIn in
            do {
                try await client.login(studentID: id, password: password)
                return client
            } catch MailClientError.authenticationFailed {
                await client.logout()
                handleAuthFailure(for: signedIn)
                throw MailClientError.authenticationFailed
            } catch {
                await client.logout()
                throw error
            }
        }
    }

    func handleAuthFailure(for signIn: SignIn) {
        guard signIn.isCurrent, !authFailed else { return }
        prefs.change(for: signIn) { $0.authFailed = true }
        authFailed = true
        listeners.authFailed?()
    }

    func logout() {
        SignOutPlan(session: session, stores: SignOutPlan.mailStores, clearRest: { [self] in
            cacheWipe.start(prefs: prefs)
            studentID = nil
            signInStatus.error = nil
            authFailed = false
            settings = MailAccountSettings(
                displayName: nil, notificationsEnabled: prefs.notificationsEnabled, muteSettings: prefs.muteSettings
            )
            listeners.signOutEvents.post(name: Self.didSignOut, object: nil)
            listeners.signedOut?()
        }).run(in: AccountStorage(mailPreferences: prefs, mailCredentials: signIn.credentials))
    }

    func resumeInterruptedCacheWipe() {
        cacheWipe.resumeIfInterrupted(prefs: prefs)
    }

    private func establishBaseline(client: any MailClient, for signIn: SignIn) async {
        guard let status = try? await client.status(folder: MailConstants.inbox) else { return }
        guard signIn.isCurrent else { return }
        MailInboxCursor(prefs: prefs).reset(to: status, for: signIn)
    }

    private func discoverDisplayName(client: any MailClient, address: String) async -> String? {
        guard let folders = try? await client.listFolders(),
              let sent = MailFolderMap.resolve(available: folders)[.sent],
              let page = try? await client.page(folder: sent, olderThanSequence: nil, pageSize: MailConstants.pageSize) else {
            return nil
        }
        return page.summaries
            .first { $0.fromAddress?.lowercased() == address.lowercased() }?
            .fromName?.mailNonEmpty
    }
}
#endif
