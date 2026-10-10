#if os(iOS)
import Foundation
import Observation

/// The School Mail account: its own login, separate from NTUST and the library.
/// Signed-in state is `prefs.studentID`, not a Keychain read, because an unreadable
/// Keychain must never look like "signed out".
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

    /// Posted by `logout()`, once per sign-out, synchronously on the main actor.
    ///
    /// An event rather than an observed `isLoggedIn`: a sign-out followed by a sign-in before an
    /// observer next looked would read as "no change", and whatever it held for the previous
    /// student — the page's authenticated IMAP connection (`MailPageSession`), the list's
    /// in-memory pages (`MailListViewModel`) — would carry straight over to the next one. An
    /// observer registered in its own `init` cannot miss one of these.
    static let didSignOut = Notification.Name("SchoolMail.didSignOut")

    private(set) var studentID: String?
    private(set) var isLoggingIn = false
    private(set) var loginError: LoginError?
    private(set) var authFailed: Bool

    /// The password the server most recently rejected for a manual sign-in. In memory for this
    /// process only: never persisted, logged or sent anywhere. The sign-in screens read it so
    /// they do not prefill it again: a Mail2000 password need not match the NTUST one, and
    /// repeated rejected `LOGIN`s lock the school account and its campus Wi-Fi. A manual
    /// rejection does not set `authFailed`, which is for a saved password failing in the
    /// background, so nothing else throttles this path. Only an accepted sign-in clears it; a
    /// sign-out does not, as the prefill would offer the same NTUST password again. Relaunching
    /// forgets it, for someone who has since changed their Mail2000 password to match.
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
    /// Which sign-in the account state belongs to. `logout()` bumps it; `login()` captures it once
    /// and re-checks it after every suspension point, so a login in flight at sign-out cannot
    /// write its session back over it (swift/TigerDuck/AGENTS.md). It is the counterpart of
    /// `pendingCacheClear`, which stops a logout's cache wipe landing after a login. `logout()` is
    /// synchronous on this `@MainActor` type, so it can only interleave at an `await`. A stale
    /// login still closes its IMAP connection, which nothing else would, and still records
    /// `lastRejectedPassword`, so that password is not offered again. Only the current sign-in
    /// may write `credentials`, `prefs`, `studentID` or `displayName`, or call `onSignedIn`.
    @ObservationIgnored private var loginGeneration = 0
    /// Where `didSignOut` is posted: `.default` for `shared`, which is what every page session and
    /// list listens on, and a private centre for any other instance — so a test's sign-outs,
    /// running in parallel with other tests, never tear down a session that is not theirs.
    @ObservationIgnored private let signOutEvents: NotificationCenter

    init(
        prefs: any MailPreferences = DefaultsMailPreferences(),
        credentials: MailCredentialStore = MailCredentialStore(),
        cache: MailCache = .shared,
        isDemoLogin: @escaping (String, String) -> Bool = { MailDemoFixture.shared?.matches(studentID: $0, password: $1) ?? false },
        makeClient: @escaping (Bool) -> any MailClient = { MailClientFactory.make(demo: $0) },
        clearCache: (@Sendable () async -> Void)? = nil,
        signOutEvents: NotificationCenter = NotificationCenter()
    ) {
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
    }

    /// Checks the credentials with an IMAP LOGIN and saves them only if it succeeds.
    func login(studentID rawID: String, password: String) async {
        let id = Self.normalizedUsername(rawID)
        guard !id.isEmpty, !password.isEmpty, !isLoggingIn else { return }
        isLoggingIn = true
        loginError = nil
        defer { isLoggingIn = false }
        // The sign-in this call is establishing. Captured before the first `await`, so every
        // check below is against the generation the user actually asked for.
        let generation = loginGeneration

        // A logout just before this login may still be clearing the cache in the
        // background (see `logout()`); wait for it to finish before this call writes
        // anything, so its clear can never land after (and wipe) this session's data.
        await pendingCacheClear?.value
        // A logout during that wait started its own wipe, now in `pendingCacheClear`. Returning
        // before it is set to nil keeps that handle, so the next login still waits for the wipe.
        // No LOGIN is sent either: the user has just signed out of this account.
        guard generation == loginGeneration else { return }
        pendingCacheClear = nil

        let demo = isDemoLogin(id, password)
        let client = makeClient(demo)
        do {
            try await client.login(studentID: id, password: password)
            // A sign-out during LOGIN has already cleared the credentials; saving would put that
            // account's password back in the Keychain for good. Closing still runs: it is cleanup.
            // Nothing suspends before `establishBaseline`, so this also guards the `prefs` writes.
            guard generation == loginGeneration else {
                await client.logout()
                return
            }
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
        await establishBaseline(client: client, generation: generation)
        if prefs.displayName == nil {
            let discovered = await discoverDisplayName(client: client, address: MailConstants.address(forStudentID: id))
            // `displayName`'s `didSet` writes straight through to `prefs`, so this is a state
            // write like any other and belongs to the sign-in that asked for it.
            if generation == loginGeneration { displayName = discovered }
        }
        // Unconditional: closing the connection this call opened is cleanup that has to happen
        // whether or not the sign-in it belonged to is still the current one.
        await client.logout()

        // The writes that make the app look signed in. After a logout anywhere above, the
        // credentials they would go with are gone, so a stale login stops here without an error:
        // the user asked to be signed out. The `defer` still lowers `isLoggingIn`.
        guard generation == loginGeneration else { return }
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
    /// Once the server has rejected the saved password, this throws without creating a client
    /// or sending another LOGIN. It never retries, even once, until the user re-enters the
    /// password through `login(studentID:password:)`, because repeated failures can lock the
    /// school account and Wi-Fi. Every caller (the page poll, pull-to-refresh, background
    /// refresh) goes through this one choke point, so nothing else needs its own `authFailed`
    /// check.
    func openSession() async throws -> any MailClient {
        guard !authFailed else { throw MailClientError.authenticationFailed }
        guard let id = prefs.studentID, let password = credentials.password() else {
            throw MailClientError.protocolError("credentials unavailable")
        }
        // The sign-in these credentials belong to — see `loginGeneration`. A sign-out while the
        // LOGIN below is on the wire makes its rejection the previous account's, and applying it
        // would stop the checks of whoever signs in next, for a password they never entered.
        let generation = loginGeneration
        let client = makeClient(prefs.demoActive)
        do {
            try await client.login(studentID: id, password: password)
            return client
        } catch MailClientError.authenticationFailed {
            await client.logout()
            if generation == loginGeneration { handleAuthFailure() }
            throw MailClientError.authenticationFailed
        } catch {
            await client.logout()
            throw error
        }
    }

    /// The server rejected the saved password: stop every background check at once and
    /// never retry, because repeated failures can lock the school account and Wi-Fi.
    func handleAuthFailure() {
        guard !authFailed else { return }
        prefs.authFailed = true
        authFailed = true
        onAuthFailed?()
    }

    /// Wipes the password, display name, markers and scheduled work synchronously, and
    /// starts wiping the on-disk caches. NTUST and library sign-in are untouched.
    ///
    /// `MailCache` does synchronous disk I/O and this type is `@MainActor`, so
    /// `cache.clearAll()` never runs inline here. It runs detached, off the main actor, and
    /// `login()` awaits it (via `pendingCacheClear`) before writing a new session's state.
    /// This method stays synchronous: callers that only care about the account and credential
    /// state, not the cache wipe finishing, need not `await`.
    func logout() {
        // Before anything is cleared, so a `login()` suspended anywhere in its tail sees the
        // bump the moment it resumes and writes none of the session it was establishing.
        loginGeneration += 1
        credentials.clear()
        prefs.reset()
        startCacheWipe()
        studentID = nil
        loginError = nil
        authFailed = false
        displayName = nil
        notificationsEnabled = prefs.notificationsEnabled
        signOutEvents.post(name: Self.didSignOut, object: nil)
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

    /// Re-runs a sign-out cache wipe that a process death interrupted. Called at launch.
    ///
    /// It goes through the same `pendingCacheClear` handle the in-process wipe uses, so
    /// `login()`'s existing wait covers it too: a student signing in seconds after launch can
    /// never have their first cached page deleted by the previous student's unfinished wipe.
    func resumeInterruptedCacheWipe() {
        guard prefs.cacheWipePending, pendingCacheClear == nil else { return }
        startCacheWipe()
    }

    /// `generation` is `login()`'s, re-checked *after* the STATUS round trip rather than before
    /// it: the markers written here are what the background checker treats as "everything up to
    /// UID n has been seen", and `prefs.reset()` is supposed to have taken them away. Writing
    /// them back after a sign-out leaves the next student's INBOX silently starting from the
    /// previous one's UID.
    private func establishBaseline(client: any MailClient, generation: Int) async {
        guard let status = try? await client.status(folder: MailConstants.inbox) else { return }
        guard generation == loginGeneration else { return }
        prefs.inboxUIDValidity = status.uidValidity
        prefs.inboxNextUID = status.uidNext
    }

    /// The display name Mail2000 webmail wrote on the newest mail in Sent that was sent from
    /// this address.
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
