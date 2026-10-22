#if os(iOS)
import Foundation

nonisolated enum MailCheckTrigger: String, Codable, Sendable {
    case page
    case foreground, backgroundTask

    var displayText: String {
        switch self {
        case .page: String(localized: "school_mail_check_trigger_page")
        case .foreground: String(localized: "school_mail_check_trigger_foreground")
        case .backgroundTask: String(localized: "school_mail_check_trigger_background")
        }
    }

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

    static let failurePrefix = "failed: "
    static let newMailSuffix = " new"

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
        case .failed(let error): String(format: String(localized: "school_mail_check_failed"), "\(error)")
        }
    }

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

    private static let valuelessCases: [MailCheckOutcome] = [
        .skippedBusy, .skippedSignedOut, .skippedDisabled, .skippedAuthFailed,
        .baselineReset, .noNewMail, .authFailed,
    ]
}

actor MailChecker {
    static let shared = MailChecker(
        prefs: DefaultsMailPreferences(),
        notifier: MailNotifier(center: SystemMailNotificationCenter()),
        openSession: { try await MailAccountManager.shared.openSession() },
        onAuthFailure: { await MailAccountManager.shared.handleAuthFailure() },
        cache: .shared,
        notificationsDenied: { await MailNotificationPermission.isDenied() }
    )

    nonisolated let notifier: MailNotifier
    private let prefs: any MailPreferences
    private let openSession: @Sendable () async throws -> any MailClient
    private let onAuthFailure: @Sendable () async -> Void
    private let now: @Sendable () -> Date
    private let cache: MailCache?
    private let notificationsDenied: @Sendable () async -> Bool
    private var isRunning = false

    init(
        prefs: any MailPreferences,
        notifier: MailNotifier,
        openSession: @escaping @Sendable () async throws -> any MailClient,
        onAuthFailure: @escaping @Sendable () async -> Void,
        now: @escaping @Sendable () -> Date = { Date() },
        cache: MailCache? = nil,
        notificationsDenied: @escaping @Sendable () async -> Bool = { false }
    ) {
        self.prefs = prefs
        self.notifier = notifier
        self.openSession = openSession
        self.onAuthFailure = onAuthFailure
        self.now = now
        self.cache = cache
        self.notificationsDenied = notificationsDenied
    }

    func check(trigger: MailCheckTrigger) async -> MailCheckOutcome {
        guard !isRunning else { return .skippedBusy }
        guard let account = prefs.studentID else { return .skippedSignedOut }
        guard !prefs.authFailed else { return .skippedAuthFailed }
        guard prefs.notificationsEnabled else { return .skippedDisabled }
        isRunning = true
        defer { isRunning = false }
        if await notificationsDenied() { return .skippedDisabled }
        guard stillSignedIn(as: account) else { return .skippedSignedOut }
        prefs.lastCheckAt = now()
        let outcome = await run(for: account)
        guard let outcome, stillSignedIn(as: account) else { return .skippedSignedOut }
        record(trigger: trigger, outcome: outcome)
        return outcome
    }

    private func stillSignedIn(as account: String) -> Bool {
        Self.resultsStillApply(startedAs: account, current: prefs.studentID)
    }

    nonisolated static func resultsStillApply(startedAs account: String, current: String?) -> Bool {
        account == current
    }

    func noteSeenByPage(_ status: MailboxStatusInfo) {
        guard prefs.studentID != nil else { return }
        if prefs.inboxUIDValidity != status.uidValidity || prefs.inboxNextUID == nil {
            prefs.inboxUIDValidity = status.uidValidity
            prefs.inboxNextUID = status.uidNext
        } else if let marker = prefs.inboxNextUID, status.uidNext > marker {
            prefs.inboxNextUID = status.uidNext
        }
    }

    private func run(for account: String) async -> MailCheckOutcome? {
        let client: any MailClient
        do {
            client = try await openSession()
        } catch MailClientError.authenticationFailed {
            await reportAuthFailure(for: account)
            return .authFailed
        } catch {
            return .failed(error as? MailClientError ?? .unreachable)
        }

        let outcome: MailCheckOutcome?
        do {
            let result = try await checkInbox(for: account, client: client)
            outcome = result?.outcome
            if let result {
                await prefetchBodies(for: account, client: client, uidValidity: result.uidValidity, uids: result.notified)
            }
        } catch MailClientError.authenticationFailed {
            await reportAuthFailure(for: account)
            outcome = .authFailed
        } catch {
            outcome = .failed(error as? MailClientError ?? .unreachable)
        }
        await client.logout()
        return outcome
    }

    private func reportAuthFailure(for account: String) async {
        guard stillSignedIn(as: account) else { return }
        await onAuthFailure()
    }

    private struct InboxCheck {
        var outcome: MailCheckOutcome
        var uidValidity: UInt32
        var notified: [UInt32] = []
    }

    private func checkInbox(for account: String, client: any MailClient) async throws -> InboxCheck? {
        let status = try await client.status(folder: MailConstants.inbox)
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
        guard stillSignedIn(as: account) else { return nil }
        let unnotified = await notifier.notify(fresh, uidValidity: status.uidValidity)
        if !stillSignedIn(as: account) { await notifier.removeAll() }
        let ceiling = fetched.map(\.uid).max().map { $0 + 1 } ?? status.uidNext
        guard stillSignedIn(as: account) else { return nil }
        let advanced = unnotified.min().map { min($0, ceiling) } ?? ceiling
        if prefs.inboxUIDValidity == status.uidValidity {
            prefs.inboxNextUID = max(advanced, prefs.inboxNextUID ?? 0)
        }
        return InboxCheck(
            outcome: fresh.isEmpty ? .noNewMail : .newMail(fresh.count),
            uidValidity: status.uidValidity,
            notified: fresh.map(\.uid)
        )
    }

    private func prefetchBodies(for account: String, client: any MailClient, uidValidity: UInt32, uids: [UInt32]) async {
        guard let cache else { return }
        let wipeCount = cache.wipeCount
        for uid in uids.sorted(by: >).prefix(MailConstants.bodyPrefetchLimit) {
            guard !Task.isCancelled, stillSignedIn(as: account) else { return }
            if cache.loadDetail(folder: MailConstants.inbox, uidValidity: uidValidity, uid: uid) != nil { continue }
            do {
                let detail = try await client.detail(folder: MailConstants.inbox, uid: uid, expectedUIDValidity: uidValidity,
                                                     inlineImages: false)
                guard !Task.isCancelled, stillSignedIn(as: account) else { return }
                cache.saveDetail(detail, folder: MailConstants.inbox, uidValidity: uidValidity, wipeCount: wipeCount)
            } catch let error as MailClientError where Self.endsPrefetch(error) {
                return
            } catch {
                continue
            }
        }
    }

    nonisolated static func endsPrefetch(_ error: MailClientError) -> Bool {
        switch error {
        case .unreachable, .certificateRejected, .authenticationFailed, .serverBusy: true
        case .searchUnsupported, .folderChanged, .sendUnconfirmed, .protocolError: false
        }
    }

    private func record(trigger: MailCheckTrigger, outcome: MailCheckOutcome) {
        var records = prefs.diagnostics
        records.insert(MailCheckRecord(date: now(), trigger: trigger.rawValue, result: outcome.diagnosticText), at: 0)
        prefs.diagnostics = Array(records.prefix(MailConstants.diagnosticsLimit))
    }
}
#endif
