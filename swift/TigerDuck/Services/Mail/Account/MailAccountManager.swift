#if os(iOS)
import Foundation
import Observation

/// The School Mail account: its own login, separate from NTUST and the library
/// (design doc §7). Signed-in state is `prefs.studentID`, not a Keychain read — an
/// unreadable Keychain must never look like "signed out".
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

    static let shared = MailAccountManager()

    private(set) var studentID: String?
    private(set) var isLoggingIn = false
    private(set) var loginError: LoginError?
    private(set) var authFailed: Bool

    /// The password the mail server most recently **rejected** for a manual sign-in.
    ///
    /// In memory for this process only: never persisted, never logged, never sent anywhere.
    /// The sign-in screens read it so they do not prefill it again — a Mail2000 password is set
    /// in webmail and need not match the NTUST one, so a mismatch is the *expected* failure
    /// here, and re-offering the rejected password made another rejected `LOGIN` a single tap
    /// on exactly the path §7.4 protects (repeated failures lock the school account and its
    /// campus Wi-Fi). A *manual* rejection deliberately does not set `authFailed`, which is
    /// reserved for a saved password failing in the background, so nothing else throttled this.
    ///
    /// Cleared by a sign-in the server accepted, and by nothing else: a sign-out does not clear
    /// it, because the password it remembers is the NTUST one the prefill would offer again and
    /// that has not become any more likely to work. Relaunching the app forgets it, which is the
    /// escape hatch for someone who has since changed their Mail2000 password to match.
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
    /// Runs `cache.clearAll()` (or, in tests, a stand-in) off the main actor — see
    /// `logout()`. Injectable so tests can observe/control exactly when a logout's clear
    /// finishes relative to a following `login()`, without touching real disk I/O timing.
    @ObservationIgnored private let clearCache: @Sendable () async -> Void
    /// The in-flight `logout()` cache clear, if any. `login()` awaits this before writing
    /// any new-session state, so a quick sign-out -> sign-in can never have its fresh
    /// cache writes raced (and wiped) by the previous session's still-running clear.
    /// Exposed (not `private`) only so tests can await it directly instead of guessing a
    /// delay; production callers never touch it.
    @ObservationIgnored private(set) var pendingCacheClear: Task<Void, Never>?

    init(
        prefs: any MailPreferences = DefaultsMailPreferences(),
        credentials: MailCredentialStore = MailCredentialStore(),
        cache: MailCache = .shared,
        isDemoLogin: @escaping (String, String) -> Bool = { MailDemoFixture.shared?.matches(studentID: $0, password: $1) ?? false },
        makeClient: @escaping (Bool) -> any MailClient = { MailClientFactory.make(demo: $0) },
        clearCache: (@Sendable () async -> Void)? = nil
    ) {
        self.prefs = prefs
        self.credentials = credentials
        self.cache = cache
        self.isDemoLogin = isDemoLogin
        self.makeClient = makeClient
        self.clearCache = clearCache ?? { cache.clearAll() }
        studentID = prefs.studentID
        authFailed = prefs.authFailed
        displayName = prefs.displayName
        notificationsEnabled = prefs.notificationsEnabled
    }

    /// Checks the credentials with an IMAP LOGIN and saves them only if it succeeds (§7.1).
    func login(studentID rawID: String, password: String) async {
        let id = Self.normalizedUsername(rawID)
        guard !id.isEmpty, !password.isEmpty, !isLoggingIn else { return }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }

        // A logout just before this login may still be clearing the cache in the
        // background (see `logout()`); wait for it to finish before this call writes
        // anything, so its clear can never land after (and wipe) this session's data.
        await pendingCacheClear?.value
        pendingCacheClear = nil

        let demo = isDemoLogin(id, password)
        let client = makeClient(demo)
        do {
            try await client.login(studentID: id, password: password)
            try credentials.savePassword(password)
        } catch {
            await client.logout()
            let failure = LoginError(error)
            // Only a *rejection* is remembered. An unreachable server or a certificate the app
            // would not trust says nothing about whether the password is right, and suppressing
            // the prefill after one of those would be friction with no safety behind it.
            if failure == .credentials { lastRejectedPassword = password }
            loginError = failure
            return
        }

        lastRejectedPassword = nil
        prefs.studentID = id
        prefs.demoActive = demo
        prefs.authFailed = false
        await establishBaseline(client: client)
        if prefs.displayName == nil {
            displayName = await discoverDisplayName(client: client, address: MailConstants.address(forStudentID: id))
        }
        await client.logout()

        authFailed = false
        studentID = id
        onSignedIn?()
    }

    /// The username as it goes to `LOGIN`: trimmed, and upper-cased — Mail2000 wants
    /// `B10000000`, which is also how the student ID is printed everywhere else in the app.
    ///
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

    /// A logged-in client for one unit of work. The caller logs it out.
    ///
    /// Once the server has rejected the saved password, this throws without creating a
    /// client or sending another LOGIN — never retried, even once, until the user re-enters
    /// the password through `login(studentID:password:)` (spec §7.4: repeated failures can
    /// lock the school account and Wi-Fi). Every caller (the page poll, pull-to-refresh,
    /// background refresh) goes through this one choke point, so nothing else needs its own
    /// `authFailed` check.
    func openSession() async throws -> any MailClient {
        guard !authFailed else { throw MailClientError.authenticationFailed }
        guard let id = prefs.studentID, let password = credentials.password() else {
            throw MailClientError.protocolError("credentials unavailable")
        }
        let client = makeClient(prefs.demoActive)
        do {
            try await client.login(studentID: id, password: password)
            return client
        } catch MailClientError.authenticationFailed {
            await client.logout()
            handleAuthFailure()
            throw MailClientError.authenticationFailed
        } catch {
            await client.logout()
            throw error
        }
    }

    /// The server rejected the saved password: stop every background check at once and
    /// never retry — repeated failures can lock the school account and Wi-Fi (§7.4).
    func handleAuthFailure() {
        guard !authFailed else { return }
        prefs.authFailed = true
        authFailed = true
        onAuthFailed?()
    }

    /// Wipes the password, display name, markers and scheduled work synchronously, and
    /// starts wiping the on-disk caches (§7.5). NTUST and library sign-in are untouched.
    ///
    /// `MailCache` does synchronous disk I/O and this type is `@MainActor`, so
    /// `cache.clearAll()` never runs inline here — it runs detached, off the main actor,
    /// and `login()` awaits it (via `pendingCacheClear`) before writing a new session's
    /// state. This method's own signature stays synchronous: callers that only care about
    /// the account/credential state (not the cache wipe finishing) don't need to `await`.
    func logout() {
        credentials.clear()
        prefs.reset()
        startCacheWipe()
        studentID = nil
        loginError = nil
        authFailed = false
        displayName = nil
        notificationsEnabled = prefs.notificationsEnabled
        onSignedOut?()
    }

    /// Starts the sign-out cache wipe and records that it is owed, so it can be finished by a
    /// later launch if this process does not survive it. The flag is set *after* `prefs.reset()`
    /// (which deliberately leaves it alone) and cleared only once the wipe has actually returned.
    private func startCacheWipe() {
        let performClear = clearCache
        let prefs = self.prefs
        prefs.cacheWipePending = true
        pendingCacheClear = Task.detached {
            await performClear()
            prefs.cacheWipePending = false
        }
    }

    /// Re-runs a sign-out cache wipe that a process death interrupted (§7.5). Called at launch.
    ///
    /// It goes through the same `pendingCacheClear` handle the in-process wipe uses, so
    /// `login()`'s existing wait covers it too: a student signing in seconds after launch can
    /// never have their first cached page deleted by the previous student's unfinished wipe.
    func resumeInterruptedCacheWipe() {
        guard prefs.cacheWipePending, pendingCacheClear == nil else { return }
        startCacheWipe()
    }

    private func establishBaseline(client: any MailClient) async {
        guard let status = try? await client.status(folder: MailConstants.inbox) else { return }
        prefs.inboxUIDValidity = status.uidValidity
        prefs.inboxNextUID = status.uidNext
    }

    /// §7.3: the display name Mail2000 webmail wrote on the newest mail in Sent that was
    /// sent from this address.
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
