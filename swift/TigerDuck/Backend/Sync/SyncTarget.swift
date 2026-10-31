import Foundation

/// Holds what this device derives from school data, its course and assignment uploads, until the
/// sign-in's first pull from the backend has been applied in this launch. An upload computed
/// before the device read the backend would otherwise leave the backend's merge rules to undo a
/// stale state. A local edit does not wait here.
@MainActor
final class SyncTarget {
    private typealias Waiter = (id: UUID, ticket: AccountSession.Ticket, resume: CheckedContinuation<Bool, Never>)

    private let account: AccountSession
    private var pulledIn: AccountSession.Ticket?
    /// In the order the uploads came, so one channel's held uploads go out oldest first.
    private var waiters: [Waiter] = []
    /// Released uploads not yet resumed. One is resumed at a time and resumes the next once it
    /// runs, as the executor may run tasks resumed together in another order.
    private var releasing: [(id: UUID, result: Bool, resume: CheckedContinuation<Bool, Never>)] = []
    private var resumed: UUID?

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

    /// True once a pull under `ticket` has been applied; false when the sign-in ended first. An
    /// upload that comes while released ones are still going on goes after them.
    func waitForPull(_ ticket: AccountSession.Ticket) async -> Bool {
        if hasPulled(ticket), releasing.isEmpty, resumed == nil { return true }
        guard account.isCurrent(ticket) else { return false }
        let id = UUID()
        let pulled = await withTaskCancellationHandler {
            await withCheckedContinuation { resume in
                if Task.isCancelled {
                    resume.resume(returning: false)
                } else if hasPulled(ticket) {
                    releasing.append((id, true, resume))
                    if resumed == nil { resumeNextReleased() }
                } else {
                    waiters.append((id, ticket, resume))
                }
            }
        } onCancel: {
            Task { @MainActor in
                guard let index = self.waiters.firstIndex(where: { $0.id == id }) else { return }
                self.waiters.remove(at: index).resume.resume(returning: false)
            }
        }
        if resumed == id { resumeNextReleased() }
        return pulled
    }

    private func release(pulled: (AccountSession.Ticket) -> Bool) {
        releasing += waiters.map { ($0.id, pulled($0.ticket) && account.isCurrent($0.ticket), $0.resume) }
        waiters = []
        if resumed == nil { resumeNextReleased() }
    }

    private func resumeNextReleased() {
        guard !releasing.isEmpty else {
            resumed = nil
            return
        }
        let next = releasing.removeFirst()
        resumed = next.id
        next.resume.resume(returning: next.result)
    }
}
