import Foundation
import Observation

/// One account's sign-in: the school account (NTUST, Moodle and the TigerDuck backend), the
/// library or School Mail. Work for a sign-in takes its `ticket` before an `await` and writes what
/// it fetched only while `isCurrent(_:)` holds. A sign-out cancels the sign-in's tasks and moves
/// the session on, so a reply that lands afterwards is dropped
/// (docs/decisions/0026-one-sign-out-path.md).
@Observable
final class AccountSession {
    /// A sign-in of the account: two tickets are equal while the session did not move on between them.
    nonisolated struct Ticket: Hashable, Comparable, Sendable {
        fileprivate let count: Int

        static func < (lhs: Ticket, rhs: Ticket) -> Bool { lhs.count < rhs.count }
    }

    /// NTUST, Moodle and the TigerDuck backend, which sign in and out together.
    static let school = AccountSession()
    static let library = AccountSession()

    private(set) var signIns = SignInCount()
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    var ticket: Ticket { signIns.ticket }

    func isCurrent(_ ticket: Ticket) -> Bool { signIns.isCurrent(ticket) }

    /// A check bound to the current sign-in, for work that writes what it fetched after an `await`.
    func currentCheck() -> () -> Bool {
        let ticket = ticket
        return { [weak self] in self?.isCurrent(ticket) ?? false }
    }

    /// Runs `work` for the current sign-in, which `stopWork()` cancels.
    @discardableResult
    func task(_ work: @escaping @MainActor (Ticket) async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let ticket = ticket
        let task = Task { @MainActor [weak self] in
            await work(ticket)
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    /// The first step of a sign-out: cancels the tasks of the departing sign-in.
    func stopWork() {
        let running = tasks.values
        tasks = [:]
        running.forEach { $0.cancel() }
    }

    /// The second step of a sign-out: every ticket taken so far reads as stale.
    func moveOn() {
        signIns.moveOn()
    }
}

/// The sign-ins of an actor that keeps its own count, as `AuthTokenManager` and
/// `MoodleTokenService` do: their sign-outs run on the actor, after the session's.
nonisolated struct SignInCount: Sendable {
    private(set) var ticket = AccountSession.Ticket(count: 0)

    func isCurrent(_ ticket: AccountSession.Ticket) -> Bool { ticket == self.ticket }

    mutating func moveOn() {
        ticket = AccountSession.Ticket(count: ticket.count &+ 1)
    }
}
