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

/// The new-mail check of design doc §8.5, shared by every trigger. Single-flight: while a
/// check runs, another returns `.skippedBusy` — which also keeps TigerDuck inside the
/// server's connection limit.
actor MailChecker {
    static let shared = MailChecker(
        prefs: DefaultsMailPreferences(),
        notifier: MailNotifier(center: SystemMailNotificationCenter()),
        openSession: { try await MailAccountManager.shared.openSession() },
        onAuthFailure: { await MailAccountManager.shared.handleAuthFailure() }
    )

    nonisolated let notifier: MailNotifier
    private let prefs: any MailPreferences
    private let openSession: @Sendable () async throws -> any MailClient
    private let onAuthFailure: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private var isRunning = false

    init(
        prefs: any MailPreferences,
        notifier: MailNotifier,
        openSession: @escaping @Sendable () async throws -> any MailClient,
        onAuthFailure: @escaping @Sendable () async -> Void,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.prefs = prefs
        self.notifier = notifier
        self.openSession = openSession
        self.onAuthFailure = onAuthFailure
        self.now = now
    }

    /// - Parameter existing: the mail page's held connection, reused instead of a new login.
    ///   The page trigger never notifies: new mail shows up in the list instead.
    ///
    /// The account is captured here, before the first `await`, and re-read before every write
    /// and before notifying (`stillSignedIn(as:)`). Everything a run produces — the shared
    /// inbox UIDVALIDITY/UIDNEXT markers, the diagnostics ring, the auth-failed flag, the
    /// notifications themselves — is keyed to nothing but "the signed-in account", so a run that
    /// outlives its own account (a sign-out, or a different student signing in while it is
    /// suspended on a socket) is holding previous-user data and must write none of it back
    /// (`AGENTS.md`: "Do not write previous-user data back after logout"). Such a run drops its
    /// results and answers `.skippedSignedOut`, which is also what it would have returned had the
    /// sign-out landed a moment earlier.
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
            outcome = try await checkInbox(for: account, client: client, notify: notify)
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

    private func checkInbox(for account: String, client: any MailClient, notify: Bool) async throws -> MailCheckOutcome? {
        let status = try await client.status(folder: MailConstants.inbox)
        // The baseline write just below is this account's answer about this account's inbox.
        guard stillSignedIn(as: account) else { return nil }
        guard prefs.inboxUIDValidity == status.uidValidity, let marker = prefs.inboxNextUID else {
            prefs.inboxUIDValidity = status.uidValidity
            prefs.inboxNextUID = status.uidNext
            return .baselineReset
        }
        guard status.uidNext > marker else { return .noNewMail }

        // `marker:*` always includes the last message, even when its UID is below marker.
        let fetched = try await client.summaries(folder: MailConstants.inbox, fromUID: marker)
            .filter { $0.uid >= marker }
        let fresh = fetched.filter { !$0.isSeen && !$0.isDeleted }.sorted { $0.uid < $1.uid }
        // Before the notify, not only before the marker write: a notification posted here names
        // the previous student's mail — sender and subject — on the new student's lock screen.
        guard stillSignedIn(as: account) else { return nil }
        // Notify before persisting the marker (design doc §8.5: notify, then advance). If a
        // BGAppRefreshTask expires or the process is killed while this await is in flight, the
        // marker is untouched, so the next check re-fetches and re-notifies these same messages
        // instead of losing them for good — safe because notification identifiers are stable
        // per (UIDVALIDITY, UID), so a repeat delivery just replaces the same notification.
        var unnotified: Set<UInt32> = []
        if notify {
            unnotified = await notifier.notify(fresh, uidValidity: status.uidValidity)
        }
        // Advance past what was actually fetched, not STATUS's UIDNEXT, so a message that
        // arrived between the two commands is neither skipped nor notified twice...
        let ceiling = fetched.map(\.uid).max().map { $0 + 1 } ?? status.uidNext
        // ...but never past a message the notification centre refused in a way it might not
        // refuse again: the design's own safety argument is "notify, then advance, so a process
        // death re-notifies", and a refused `add` is a failure to notify that is not a process
        // death. Holding the marker at the lowest such UID makes the next check reconsider it.
        // A refusal that will be repeated for the same reason — permission off, content the
        // system will not take — is not in `unnotified` at all, because holding for one of those
        // would re-report the same mail as new on every poll for ever (`MailNotifier.isTransient`).
        // Still monotonic: every fetched UID is at or above the marker this check started from,
        // so this can only hold or advance it.
        //
        // Monotonic *for this account*, which is why the guard is repeated after the notify
        // await: the marker key is shared, and a sign-in that happened while the notifications
        // were being posted has already written its own baseline there (`establishBaseline`).
        // Advancing it from this run's fetch would move the new account's marker over mail it
        // has never seen, which is mail it would then never be notified about.
        guard stillSignedIn(as: account) else { return nil }
        prefs.inboxNextUID = unnotified.min().map { min($0, ceiling) } ?? ceiling
        return fresh.isEmpty ? .noNewMail : .newMail(fresh.count)
    }

    private func record(trigger: MailCheckTrigger, outcome: MailCheckOutcome) {
        var records = prefs.diagnostics
        records.insert(MailCheckRecord(date: now(), trigger: trigger.rawValue, result: outcome.diagnosticText), at: 0)
        prefs.diagnostics = Array(records.prefix(MailConstants.diagnosticsLimit))
    }
}
#endif
