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
    private(set) var isLoggingIn = false
    private(set) var loginError: LoginError?
    private(set) var authFailed: Bool {
        didSet { if authFailed != oldValue { authBannerDismissed = false } }
    }
    var authBannerDismissed = false
    var showsAuthFailedBanner: Bool { authFailed && !authBannerDismissed }

    @ObservationIgnored private(set) var lastRejectedPassword: String?

    var displayName: String? {
        didSet { prefs.displayName = displayName?.mailNonEmpty }
    }

    var notificationsEnabled: Bool {
        didSet {
            guard notificationsEnabled != oldValue else { return }
            prefs.notificationsEnabled = notificationsEnabled
            guard isLoggedIn else { return }
            if notificationsEnabled { onNotificationsEnabled?() } else { onNotificationsDisabled?() }
        }
    }

    var muteSettings: MailMuteSettings {
        didSet { prefs.muteSettings = muteSettings }
    }

    var isLoggedIn: Bool { studentID != nil }
    var address: String? { studentID.map(MailConstants.address(forStudentID:)) }
    var isDemo: Bool { prefs.demoActive }

    @ObservationIgnored var onSignedIn: (() -> Void)?
    @ObservationIgnored var onSignedOut: (() -> Void)?
    @ObservationIgnored var onAuthFailed: (() -> Void)?
    @ObservationIgnored var onNotificationsEnabled: (() -> Void)?
    @ObservationIgnored var onNotificationsDisabled: (() -> Void)?

    @ObservationIgnored let prefs: any MailPreferences
    @ObservationIgnored let cache: MailCache
    @ObservationIgnored private let credentials: MailCredentialStore
    @ObservationIgnored private let isDemoLogin: (String, String) -> Bool
    @ObservationIgnored private let makeClient: (Bool) -> any MailClient
    @ObservationIgnored private let clearCache: @Sendable () async -> Void
    @ObservationIgnored private(set) var pendingCacheClear: Task<Void, Never>?
    @ObservationIgnored let session: AccountSession
    @ObservationIgnored private let signOutEvents: NotificationCenter

    init(
        prefs: any MailPreferences = DefaultsMailPreferences(),
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
        self.signOutEvents = signOutEvents
        self.credentials = credentials
        self.cache = cache
        self.isDemoLogin = isDemoLogin
        self.makeClient = makeClient
        self.clearCache = clearCache ?? { cache.clearAll() }
        studentID = prefs.studentID
        authFailed = prefs.authFailed
        displayName = prefs.displayName
        notificationsEnabled = prefs.notificationsEnabled
        muteSettings = prefs.muteSettings
    }

    func login(studentID rawID: String, password: String) async {
        let id = Self.normalizedUsername(rawID)
        guard !id.isEmpty, !password.isEmpty, !isLoggingIn else { return }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        let ticket = session.ticket

        await pendingCacheClear?.value
        guard session.isCurrent(ticket) else { return }
        pendingCacheClear = nil

        let demo = isDemoLogin(id, password)
        let client = makeClient(demo)
        do {
            try await client.login(studentID: id, password: password)
            guard session.isCurrent(ticket) else {
                await client.logout()
                return
            }
            try credentials.savePassword(password)
        } catch {
            await client.logout()
            let failure = LoginError(error)
            if failure == .credentials { lastRejectedPassword = password }
            loginError = failure
            return
        }

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
        onSignedIn?()
    }

    /// The username as it goes to `LOGIN`: trimmed, and upper-cased — Mail2000 wants
    /// `B10000000`, which is also how the student ID is printed everywhere else in the app.
    /// A username that is an email address keeps the case it was typed in. RFC 5321 §2.3.11
    /// makes the local part case-*sensitive* and leaves the choice to the receiving server, so
    /// folding it is the one thing this must not do to an address; a school student ID never
    /// contains `@`, so the real path is upper-cased exactly as before. This exists so the
    /// DEBUG developer override can sign in to a server whose usernames are addresses.
    static func normalizedUsername(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.contains("@") ? trimmed : trimmed.uppercased()
    }

    func clearLoginError() {
        loginError = nil
    }

    func openSession() async throws -> any MailClient {
        guard !authFailed else { throw MailClientError.authenticationFailed }
        guard let id = prefs.studentID, let password = credentials.password() else {
            throw MailClientError.protocolError("credentials unavailable")
        }
        let ticket = session.ticket
        let client = makeClient(prefs.demoActive)
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
        onAuthFailed?()
    }

    func logout() {
        session.moveOn()
        credentials.clear()
        prefs.reset()
        startCacheWipe()
        studentID = nil
        loginError = nil
        authFailed = false
        displayName = nil
        notificationsEnabled = prefs.notificationsEnabled
        muteSettings = prefs.muteSettings
        signOutEvents.post(name: Self.didSignOut, object: nil)
        onSignedOut?()
    }

    private func startCacheWipe() {
        let performClear = clearCache
        let prefs = self.prefs
        prefs.cacheWipePending = true
        pendingCacheClear = Task.detached {
            await performClear()
            prefs.cacheWipePending = false
        }
    }

    func resumeInterruptedCacheWipe() {
        guard prefs.cacheWipePending, pendingCacheClear == nil else { return }
        startCacheWipe()
    }

    private func establishBaseline(client: any MailClient, ticket: AccountSession.Ticket) async {
        guard let status = try? await client.status(folder: MailConstants.inbox) else { return }
        guard session.isCurrent(ticket) else { return }
        prefs.inboxUIDValidity = status.uidValidity
        prefs.inboxNextUID = status.uidNext
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
