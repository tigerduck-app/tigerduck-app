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

    static let shared = MailAccountManager(signOutEvents: .default)

    ///
    static let didSignOut = Notification.Name("SchoolMail.didSignOut")

    private(set) var studentID: String?
    private var signInStatus = MailLoginStatus()
    private var auth: MailAuthFailure
    private var settings: MailAccountSettings
    /// The sign-in form does not fill this password in again.
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

    var displayName: String? {
        get { settings.displayName }
        set {
            settings.displayName = newValue
            prefs.displayName = newValue?.mailNonEmpty
        }
    }

    var notificationsEnabled: Bool {
        get { settings.notificationsEnabled }
        set {
            let changed = newValue != settings.notificationsEnabled
            settings.notificationsEnabled = newValue
            guard changed else { return }
            prefs.notificationsEnabled = newValue
            guard isLoggedIn else { return }
            if newValue { listeners.notificationsEnabled?() } else { listeners.notificationsDisabled?() }
        }
    }

    var muteSettings: MailMuteSettings {
        get { settings.muteSettings }
        set {
            settings.muteSettings = newValue
            prefs.muteSettings = newValue
        }
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
        var ticket = session.ticket

        await cacheWipe.pending?.value
        guard session.isCurrent(ticket) else { return }
        cacheWipe.forgetFinished()

        let demo = signIn.isDemoLogin(id, password)
        let client = signIn.makeClient(demo)
        do {
            try await client.login(studentID: id, password: password)
            guard session.isCurrent(ticket) else {
                await client.logout()
                return
            }
            try signIn.credentials.savePassword(password)
        } catch {
            await client.logout()
            let failure = LoginError(error)
            if failure == .credentials { lastRejectedPassword = password }
            signInStatus.error = failure
            return
        }
        // A session opened with the password this replaced must not mark this sign-in failed.
        session.moveOn()
        ticket = session.ticket

        lastRejectedPassword = nil
        prefs.studentID = id
        prefs.demoActive = demo
        prefs.authFailed = false
        await establishBaseline(client: client, ticket: ticket)
        if prefs.displayName == nil {
            let discovered = await discoverDisplayName(client: client, address: MailConstants.address(forStudentID: id))
            if session.isCurrent(ticket) { displayName = discovered }
        }
        await client.logout()

        guard session.isCurrent(ticket) else { return }
        authFailed = false
        studentID = id
        listeners.signedIn?()
    }

    /// The username as it goes to `LOGIN`: trimmed, and upper-cased, Mail2000 wants
    /// `B10000000`, which is also how the student ID is printed everywhere else in the app.
    /// A username that is an email address keeps the case it was typed in. RFC 5321 §2.3.11
    /// makes the local part case-*sensitive* and leaves the choice to the receiving server, so
    /// folding it is the one thing this must not do to an address; a school student ID never
    /// contains `@`, so the real path is upper-cased as before. This exists so the
    /// DEBUG developer override can sign in to a server whose usernames are addresses.
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
        let ticket = session.ticket
        let client = signIn.makeClient(prefs.demoActive)
        do {
            try await client.login(studentID: id, password: password)
            return client
        } catch MailClientError.authenticationFailed {
            await client.logout()
            if session.isCurrent(ticket) { handleAuthFailure() }
            throw MailClientError.authenticationFailed
        } catch {
            await client.logout()
            throw error
        }
    }

    func handleAuthFailure() {
        guard !authFailed else { return }
        prefs.authFailed = true
        authFailed = true
        listeners.authFailed?()
    }

    /// School Mail's sign-out, which keeps the school and library accounts. A sign-in waits for
    /// the cache wipe it starts.
    func logout() {
        SignOutPlan(session: session, stores: SignOutPlan.mailStores, clearRest: { [self] in
            cacheWipe.start(prefs: prefs)
            studentID = nil
            signInStatus.error = nil
            authFailed = false
            displayName = nil
            notificationsEnabled = prefs.notificationsEnabled
            muteSettings = prefs.muteSettings
            listeners.signOutEvents.post(name: Self.didSignOut, object: nil)
            listeners.signedOut?()
        }).run(in: AccountStorage(mailPreferences: prefs, mailCredentials: signIn.credentials))
    }

    func resumeInterruptedCacheWipe() {
        cacheWipe.resumeIfInterrupted(prefs: prefs)
    }

    private func establishBaseline(client: any MailClient, ticket: AccountSession.Ticket) async {
        guard let status = try? await client.status(folder: MailConstants.inbox) else { return }
        guard session.isCurrent(ticket) else { return }
        MailInboxCursor(prefs: prefs).reset(to: status)
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
