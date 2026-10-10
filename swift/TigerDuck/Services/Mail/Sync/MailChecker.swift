#if os(iOS)
import Foundation

nonisolated enum MailCheckTrigger: String, Codable, Sendable {
    case page, foreground, backgroundTask

    /// What the Notifications → School Mail diagnostics row shows. `rawValue` stays the stored
    /// form — records already on disk carry it, and it is what a bug report is read against
    /// whatever language the reporter's phone is in.
    var displayText: String {
        switch self {
        case .page: String(localized: "school_mail_check_trigger_page")
        case .foreground: String(localized: "school_mail_check_trigger_foreground")
        case .backgroundTask: String(localized: "school_mail_check_trigger_background")
        }
    }

    /// The localized form of a stored `MailCheckRecord.trigger`. A raw value this build does not
    /// know — a record written by an older version — is shown as written rather than dropped.
    static func displayText(forStored raw: String) -> String {
        MailCheckTrigger(rawValue: raw)?.displayText ?? raw
    }
}

nonisolated enum MailCheckOutcome: Equatable, Sendable {
    case skippedBusy, skippedSignedOut, skippedDisabled, skippedAuthFailed
    case baselineReset, noNewMail
    case newMail(Int)
    case authFailed
    case failed(MailClientError)

    var isSuccess: Bool {
        switch self {
        case .authFailed, .failed: false
        default: true
        }
    }

    /// The **stored** form, written into `MailCheckRecord.result`. Deliberately English and
    /// deliberately unchanged: it is what every record already on disk contains, and what a
    /// pasted diagnostic reads as whatever language the phone that wrote it was in.
    /// `displayText(forStored:)` is what the screen shows.
    var diagnosticText: String {
        switch self {
        case .skippedBusy: "skipped: another check running"
        case .skippedSignedOut: "skipped: signed out"
        case .skippedDisabled: "skipped: notifications off"
        case .skippedAuthFailed: "skipped: sign-in failed"
        case .baselineReset: "baseline reset"
        case .noNewMail: "no new mail"
        case .newMail(let count): "\(count)\(Self.newMailSuffix)"
        case .authFailed: "sign-in failed"
        case .failed(let error): "\(Self.failurePrefix)\(error)"
        }
    }

    /// The two parts of `diagnosticText` that carry a value. Named constants so the reverse map
    /// below cannot drift from the text it has to recognize.
    static let failurePrefix = "failed: "
    static let newMailSuffix = " new"

    /// What the Notifications → School Mail diagnostics row shows. That screen is gated only on
    /// `SchoolMailAvailability.isEnabled`, not on DEBUG, so it is an ordinary user-facing screen
    /// and raw enum text does not belong on it.
    var displayText: String {
        switch self {
        case .skippedBusy: String(localized: "school_mail_check_skipped_busy")
        case .skippedSignedOut: String(localized: "school_mail_check_skipped_signed_out")
        case .skippedDisabled: String(localized: "school_mail_check_skipped_disabled")
        case .skippedAuthFailed: String(localized: "school_mail_check_skipped_auth_failed")
        case .baselineReset: String(localized: "school_mail_check_baseline_reset")
        case .noNewMail: String(localized: "school_mail_check_no_new_mail")
        case .newMail(let count): String(format: String(localized: "school_mail_new_mail_count"), String(count))
        case .authFailed: String(localized: "school_mail_check_sign_in_failed")
        // The underlying error stays as it was thrown: it is the only thing on this screen a
        // bug report can be diagnosed from, and translating it would lose that.
        case .failed(let error): String(format: String(localized: "school_mail_check_failed"), "\(error)")
        }
    }

    /// The localized form of a stored `MailCheckRecord.result`.
    ///
    /// The record persists `diagnosticText`, so this maps that stable text back onto the case
    /// that wrote it rather than changing what is stored. The value-less cases are matched
    /// through `diagnosticText` itself, so the two can never drift; a string this build does not
    /// recognize (a record from an older version) is shown as written rather than dropped.
    static func displayText(forStored stored: String) -> String {
        if let known = valuelessCases.first(where: { $0.diagnosticText == stored }) {
            return known.displayText
        }
        if stored.hasPrefix(failurePrefix) {
            return String(format: String(localized: "school_mail_check_failed"),
                          String(stored.dropFirst(failurePrefix.count)))
        }
        if stored.hasSuffix(newMailSuffix), let count = Int(stored.dropLast(newMailSuffix.count)) {
            return String(format: String(localized: "school_mail_new_mail_count"), String(count))
        }
        return stored
    }

    /// Every case whose stored text carries no value, and so round-trips exactly.
    private static let valuelessCases: [MailCheckOutcome] = [
        .skippedBusy, .skippedSignedOut, .skippedDisabled, .skippedAuthFailed,
        .baselineReset, .noNewMail, .authFailed,
    ]
}

/// The new-mail check, shared by every trigger. Single-flight: while a check runs, another
/// returns `.skippedBusy`, which also keeps TigerDuck inside the server's connection limit.
actor MailChecker {
    static let shared = MailChecker(
        prefs: DefaultsMailPreferences(),
        notifier: MailNotifier(center: SystemMailNotificationCenter()),
        openSession: { try await MailAccountManager.shared.openSession() },
        onAuthFailure: { await MailAccountManager.shared.handleAuthFailure() },
        cache: .shared
    )

    nonisolated let notifier: MailNotifier
    private let prefs: any MailPreferences
    private let openSession: @Sendable () async throws -> any MailClient
    private let onAuthFailure: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    /// Where `prefetchBodies` puts the bodies of the mail a check notified about. `nil` turns the
    /// prefetch off — the default, so a test that is not about it never writes a cache anywhere.
    private let cache: MailCache?
    private var isRunning = false

    init(
        prefs: any MailPreferences,
        notifier: MailNotifier,
        openSession: @escaping @Sendable () async throws -> any MailClient,
        onAuthFailure: @escaping @Sendable () async -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        cache: MailCache? = nil
    ) {
        self.prefs = prefs
        self.notifier = notifier
        self.openSession = openSession
        self.onAuthFailure = onAuthFailure
        self.now = now
        self.cache = cache
    }

    /// - Parameter existing: the mail page's held connection, reused instead of a new login.
    ///   The page trigger never notifies: new mail shows up in the list instead.
    ///
    /// The account is captured before the first `await` and re-checked (`stillSignedIn(as:)`)
    /// before every write and before notifying. The inbox UIDVALIDITY/UIDNEXT markers, the
    /// diagnostics ring, the auth-failed flag and the notifications are keyed only to whoever is
    /// signed in, so a run that outlives its account (a sign-out, or another student signing in
    /// mid-run) writes nothing back (swift/TigerDuck/AGENTS.md) and returns `.skippedSignedOut`.
    func check(trigger: MailCheckTrigger, using existing: (any MailClient)? = nil) async -> MailCheckOutcome {
        guard !isRunning else { return .skippedBusy }
        guard let account = prefs.studentID else { return .skippedSignedOut }
        guard !prefs.authFailed else { return .skippedAuthFailed }
        guard trigger == .page || prefs.notificationsEnabled else { return .skippedDisabled }
        isRunning = true
        defer { isRunning = false }
        prefs.lastCheckAt = now()
        let outcome = await run(for: account, notify: trigger != .page, existing: existing)
        // Re-checked here as well as inside the run: `run` ends with a `logout()` await of its
        // own, and the diagnostics ring is shared with whatever account is signed in now.
        guard let outcome, stillSignedIn(as: account) else { return .skippedSignedOut }
        record(trigger: trigger, outcome: outcome)
        return outcome
    }

    /// Whether the account this run started under is still the signed-in one, read fresh from
    /// `prefs` at the moment it is asked.
    private func stillSignedIn(as account: String) -> Bool {
        Self.resultsStillApply(startedAs: account, current: prefs.studentID)
    }

    /// Whether a check's results still belong to the account that is signed in. `nil` is a
    /// sign-out and a different ID is a different student; both make the results previous-user
    /// data. Pure and `nonisolated` so it can be tested on its own.
    nonisolated static func resultsStillApply(startedAs account: String, current: String?) -> Bool {
        account == current
    }

    /// `nil` when the run's account went away partway through — see `check`.
    private func run(for account: String, notify: Bool, existing: (any MailClient)?) async -> MailCheckOutcome? {
        let client: any MailClient
        if let existing {
            client = existing
        } else {
            do {
                client = try await openSession()
            } catch MailClientError.authenticationFailed {
                await reportAuthFailure(for: account)
                return .authFailed
            } catch {
                return .failed(error as? MailClientError ?? .unreachable)
            }
        }

        let outcome: MailCheckOutcome?
        do {
            let result = try await checkInbox(for: account, client: client, notify: notify)
            outcome = result?.outcome
            // Last, after `checkInbox` has written the marker: warming bodies is optional and the
            // slowest step, up to five fetches on what may be a weak connection. Run before the
            // advance, a process death during it would re-notify all these mails on the next check.
            if notify, let result {
                await prefetchBodies(for: account, client: client, uidValidity: result.uidValidity, uids: result.notified)
            }
        } catch MailClientError.authenticationFailed {
            await reportAuthFailure(for: account)
            outcome = .authFailed
        } catch {
            outcome = .failed(error as? MailClientError ?? .unreachable)
        }
        if existing == nil { await client.logout() }
        return outcome
    }

    /// `onAuthFailure` writes the shared auth-failed flag and cancels background refresh, so a
    /// rejection of *this* run's account that arrives after someone else has signed in must not
    /// be reported: it would stop the new account's checks with a failure that was never theirs.
    /// The outcome itself is dropped by `check` either way.
    private func reportAuthFailure(for account: String) async {
        guard stillSignedIn(as: account) else { return }
        await onAuthFailure()
    }

    /// What `checkInbox` found: the outcome, plus the mail it notified about and the UIDVALIDITY
    /// those UIDs belong to, for `prefetchBodies`.
    private struct InboxCheck {
        var outcome: MailCheckOutcome
        var uidValidity: UInt32
        var notified: [UInt32] = []
    }

    private func checkInbox(for account: String, client: any MailClient, notify: Bool) async throws -> InboxCheck? {
        let status = try await client.status(folder: MailConstants.inbox)
        // The baseline write just below is this account's answer about this account's inbox.
        guard stillSignedIn(as: account) else { return nil }
        guard prefs.inboxUIDValidity == status.uidValidity, let marker = prefs.inboxNextUID else {
            prefs.inboxUIDValidity = status.uidValidity
            prefs.inboxNextUID = status.uidNext
            return InboxCheck(outcome: .baselineReset, uidValidity: status.uidValidity)
        }
        guard status.uidNext > marker else { return InboxCheck(outcome: .noNewMail, uidValidity: status.uidValidity) }

        // `marker:*` always includes the last message, even when its UID is below marker.
        let fetched = try await client.summaries(folder: MailConstants.inbox, fromUID: marker)
            .filter { $0.uid >= marker }
        let fresh = fetched.filter { !$0.isSeen && !$0.isDeleted }.sorted { $0.uid < $1.uid }
        // Before the notify, not only before the marker write: a notification posted here names
        // the previous student's mail — sender and subject — on the new student's lock screen.
        guard stillSignedIn(as: account) else { return nil }
        // Notify, then advance the marker: if a BGAppRefreshTask expires or the process dies during
        // this await, the next check re-notifies these mails instead of losing them. Identifiers
        // are stable per (UIDVALIDITY, UID), so a repeat delivery replaces the same notification.
        var unnotified: Set<UInt32> = []
        if notify {
            unnotified = await notifier.notify(fresh, uidValidity: status.uidValidity)
            // A sign-out while these were being posted ran its own `removeAll`, possibly before
            // the last of them arrived. A run that outlived its account takes back what it
            // posted, so the previous student's sender and subject do not stay on the lock screen.
            if !stillSignedIn(as: account) { await notifier.removeAll() }
        }
        // Advance past what was actually fetched, not STATUS's UIDNEXT, so a message that
        // arrived between the two commands is neither skipped nor notified twice...
        let ceiling = fetched.map(\.uid).max().map { $0 + 1 } ?? status.uidNext
        // ...but hold at the lowest UID whose refusal may not recur (`MailNotifier.notify`) so the
        // next check retries it. No fetched UID is below the old marker, so it never moves back.
        // Re-check the account: the key is shared, and a sign-in mid-notify wrote its own baseline.
        guard stillSignedIn(as: account) else { return nil }
        prefs.inboxNextUID = unnotified.min().map { min($0, ceiling) } ?? ceiling
        return InboxCheck(
            outcome: fresh.isEmpty ? .noNewMail : .newMail(fresh.count),
            uidValidity: status.uidValidity,
            notified: notify ? fresh.map(\.uid) : []
        )
    }

    /// Pulls the newest notified mails' bodies down on the connection this check already holds,
    /// so tapping the notification opens a mail that is already on disk rather than a spinner.
    ///
    /// At most `MailConstants.bodyPrefetchLimit`, newest first, so a burst of mail cannot make a
    /// quick check long, least of all in a `BGAppRefreshTask`. Silent: the check has already done
    /// its job, and a body that does not come down is fetched when the mail is opened. Stops on
    /// cancellation (the background task's expiration handler) and on an error that means the
    /// connection is gone. `detail` fetches with `BODY.PEEK`, so nothing here marks a mail read.
    private func prefetchBodies(for account: String, client: any MailClient, uidValidity: UInt32, uids: [UInt32]) async {
        guard let cache else { return }
        for uid in uids.sorted(by: >).prefix(MailConstants.bodyPrefetchLimit) {
            // The cache stamps whoever is signed in *now*; a body fetched for the previous
            // student must not be filed under the next one.
            guard !Task.isCancelled, stillSignedIn(as: account) else { return }
            if cache.loadDetail(folder: MailConstants.inbox, uidValidity: uidValidity, uid: uid) != nil { continue }
            do {
                let detail = try await client.detail(folder: MailConstants.inbox, uid: uid, expectedUIDValidity: uidValidity)
                guard !Task.isCancelled, stillSignedIn(as: account) else { return }
                cache.saveDetail(detail, folder: MailConstants.inbox, uidValidity: uidValidity)
            } catch let error as MailClientError where Self.endsPrefetch(error) {
                return
            } catch {
                continue
            }
        }
    }

    /// Whether a failed body fetch says the connection itself is unusable, so the rest would only
    /// fail the same way — or, for a rejected login, add to the failures NTUST counts towards a
    /// lockout. A protocol error or a recreated folder is about one message, and the next may
    /// still come down.
    nonisolated static func endsPrefetch(_ error: MailClientError) -> Bool {
        switch error {
        case .unreachable, .certificateRejected, .authenticationFailed, .serverBusy: true
        case .searchUnsupported, .folderChanged, .protocolError: false
        }
    }

    private func record(trigger: MailCheckTrigger, outcome: MailCheckOutcome) {
        var records = prefs.diagnostics
        records.insert(MailCheckRecord(date: now(), trigger: trigger.rawValue, result: outcome.diagnosticText), at: 0)
        prefs.diagnostics = Array(records.prefix(MailConstants.diagnosticsLimit))
    }
}
#endif
