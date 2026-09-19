#if os(iOS)
import Foundation

nonisolated enum MailCheckTrigger: String, Codable, Sendable {
    case page, foreground, backgroundTask
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

    /// Shown in Notification diagnostics next to the time and trigger.
    var diagnosticText: String {
        switch self {
        case .skippedBusy: "skipped: another check running"
        case .skippedSignedOut: "skipped: signed out"
        case .skippedDisabled: "skipped: notifications off"
        case .skippedAuthFailed: "skipped: sign-in failed"
        case .baselineReset: "baseline reset"
        case .noNewMail: "no new mail"
        case .newMail(let count): "\(count) new"
        case .authFailed: "sign-in failed"
        case .failed(let error): "failed: \(error)"
        }
    }
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
    func check(trigger: MailCheckTrigger, using existing: (any MailClient)? = nil) async -> MailCheckOutcome {
        guard !isRunning else { return .skippedBusy }
        guard prefs.studentID != nil else { return .skippedSignedOut }
        guard !prefs.authFailed else { return .skippedAuthFailed }
        guard trigger == .page || prefs.notificationsEnabled else { return .skippedDisabled }
        isRunning = true
        defer { isRunning = false }
        prefs.lastCheckAt = now()
        let outcome = await run(notify: trigger != .page, existing: existing)
        record(trigger: trigger, outcome: outcome)
        return outcome
    }

    private func run(notify: Bool, existing: (any MailClient)?) async -> MailCheckOutcome {
        let client: any MailClient
        if let existing {
            client = existing
        } else {
            do {
                client = try await openSession()
            } catch MailClientError.authenticationFailed {
                await onAuthFailure()
                return .authFailed
            } catch {
                return .failed(error as? MailClientError ?? .unreachable)
            }
        }

        let outcome: MailCheckOutcome
        do {
            outcome = try await checkInbox(client: client, notify: notify)
        } catch MailClientError.authenticationFailed {
            await onAuthFailure()
            outcome = .authFailed
        } catch {
            outcome = .failed(error as? MailClientError ?? .unreachable)
        }
        if existing == nil { await client.logout() }
        return outcome
    }

    private func checkInbox(client: any MailClient, notify: Bool) async throws -> MailCheckOutcome {
        let status = try await client.status(folder: MailConstants.inbox)
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
