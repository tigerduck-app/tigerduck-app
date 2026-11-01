import Foundation
import Observation

@Observable
final class AccountSession {
    nonisolated struct Ticket: Hashable, Comparable, Sendable {
        fileprivate let count: Int

        static func < (lhs: Ticket, rhs: Ticket) -> Bool { lhs.count < rhs.count }
    }

    static let school = AccountSession()
    static let library = AccountSession()

    private(set) var signIns = SignInCount()
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    var ticket: Ticket { signIns.ticket }

    func isCurrent(_ ticket: Ticket) -> Bool { signIns.isCurrent(ticket) }

    func currentCheck() -> () -> Bool {
        let ticket = ticket
        return { [weak self] in self?.isCurrent(ticket) ?? false }
    }

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

    func stopWork() {
        let running = tasks.values
        tasks = [:]
        running.forEach { $0.cancel() }
    }

    func moveOn() {
        signIns.moveOn()
    }
}

struct SignInScoped<Value> {
    private let empty: Value
    private var held: (signIn: AccountSession.Ticket, value: Value)?

    init(empty: Value) {
        self.empty = empty
    }

    func value(in session: AccountSession) -> Value {
        guard let held, session.isCurrent(held.signIn) else { return empty }
        return held.value
    }

    mutating func set(_ value: Value, in session: AccountSession) {
        held = (session.ticket, value)
    }
}

nonisolated struct SignInCount: Sendable {
    private(set) var ticket = AccountSession.Ticket(count: 0)

    func isCurrent(_ ticket: AccountSession.Ticket) -> Bool { ticket == self.ticket }

    mutating func moveOn() {
        ticket = AccountSession.Ticket(count: ticket.count &+ 1)
    }
}
