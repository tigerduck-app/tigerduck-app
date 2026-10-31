import Foundation

/// Holds what this device derives from school data, its course and assignment uploads, until the
/// sign-in's first pull from the backend has been applied in this launch. An upload computed
/// before the device read the backend would otherwise leave the backend's merge rules to undo a
/// stale state. A local edit does not wait here.
@MainActor
final class SyncTarget {
    private let account: AccountSession
    private var pulledIn: AccountSession.Ticket?
    private var waiters: [UUID: (ticket: AccountSession.Ticket, resume: CheckedContinuation<Bool, Never>)] = [:]

    init(account: AccountSession) {
        self.account = account
    }

    func hasPulled(_ ticket: AccountSession.Ticket) -> Bool {
        pulledIn == ticket && account.isCurrent(ticket)
    }

    /// A pull under `ticket` has been applied; the uploads waiting for it go.
    func notePull(_ ticket: AccountSession.Ticket) {
        guard account.isCurrent(ticket) else { return }
        pulledIn = ticket
        release { $0 == ticket }
    }

    /// The sign-in ended: its waiting uploads are dropped, and the next sign-in pulls first.
    func signedOut() {
        pulledIn = nil
        release { _ in false }
    }

    /// True once a pull under `ticket` has been applied; false when the sign-in ended first.
    func waitForPull(_ ticket: AccountSession.Ticket) async -> Bool {
        if hasPulled(ticket) { return true }
        guard account.isCurrent(ticket) else { return false }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                if Task.isCancelled { resume.resume(returning: false) } else { waiters[id] = (ticket, resume) }
            }
        } onCancel: {
            Task { @MainActor in self.waiters.removeValue(forKey: id)?.resume.resume(returning: false) }
        }
    }

    private func release(pulled: (AccountSession.Ticket) -> Bool) {
        let released = waiters
        waiters = [:]
        for waiter in released.values {
            waiter.resume.resume(returning: pulled(waiter.ticket) && account.isCurrent(waiter.ticket))
        }
    }
}
