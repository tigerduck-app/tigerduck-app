import Foundation
import Observation
import os

/// One sign-in of an account. Account data read or fetched for it is written and sent only
/// while it is current; the account's sign-out ends it. See
/// docs/decisions/0029-account-bound-writes.md.
nonisolated struct SignIn: Hashable, Sendable {
    fileprivate let series: SignInSeries
    fileprivate let number: Int
    /// The store-review account's, whose data comes from `demo.json` and which sends nothing.
    let isDemo: Bool

    var isCurrent: Bool { series.holds(number) }

    static func == (lhs: SignIn, rhs: SignIn) -> Bool {
        lhs.series === rhs.series && lhs.number == rhs.number
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(series))
        hasher.combine(number)
    }
}

/// An account's sign-ins, one after another, readable from any actor.
nonisolated final class SignInSeries: Sendable {
    private struct Current {
        var number = 0
        var isDemo = false
    }

    private let current = OSAllocatedUnfairLock(initialState: Current())

    var currentSignIn: SignIn {
        current.withLock { SignIn(series: self, number: $0.number, isDemo: $0.isDemo) }
    }

    fileprivate func holds(_ number: Int) -> Bool { current.withLock { $0.number == number } }

    /// The app ends a sign-in through `AccountSession.endSignIn`, which also stops its work.
    func end() { current.withLock { $0 = Current(number: $0.number &+ 1) } }

    /// Ends the current sign-in for one of the store-review account.
    func startDemo() { current.withLock { $0 = Current(number: $0.number &+ 1, isDemo: true) } }
}

@Observable
final class AccountSession {
    nonisolated static let schoolSignIns = SignInSeries()
    nonisolated static let school = AccountSession(signIns: schoolSignIns)
    nonisolated static let library = AccountSession()
    nonisolated static let mail = AccountSession()

    nonisolated let signIns: SignInSeries
    private var ended = 0
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    nonisolated init(signIns: SignInSeries = SignInSeries()) {
        self.signIns = signIns
    }

    @available(*, noasync, message: "async work takes its sign-in as a parameter or runs as the session's task")
    var currentSignIn: SignIn {
        _ = ended
        return signIns.currentSignIn
    }

    /// The sign-in async work runs for, read where the work starts.
    var startingSignIn: SignIn {
        get async { signIns.currentSignIn }
    }

    @discardableResult
    func withSignIn<Value>(_ work: (SignIn) async throws -> Value) async rethrows -> Value {
        try await work(signIns.currentSignIn)
    }

    @discardableResult
    func task(_ work: @escaping @MainActor (SignIn) async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let signIn = signIns.currentSignIn
        let task = Task { @MainActor [weak self] in
            await work(signIn)
            self?.tasks[id] = nil
        }
        tasks[id] = task
        return task
    }

    /// Ends the current sign-in and cancels its tasks; the sign-in it returns follows it.
    @discardableResult
    func endSignIn() -> SignIn { endSignIn { $0.end() } }

    /// Ends the current sign-in as `endSignIn` does, followed by one of the store-review account.
    @discardableResult
    func startDemoSignIn() -> SignIn { endSignIn { $0.startDemo() } }

    private func endSignIn(_ startNext: (SignInSeries) -> Void) -> SignIn {
        let running = tasks.values
        tasks = [:]
        startNext(signIns)
        ended &+= 1
        running.forEach { $0.cancel() }
        return signIns.currentSignIn
    }
}

/// A value that holds for one sign-in and reads as `empty` once that sign-in ended.
nonisolated struct SignInBound<Value> {
    private let empty: Value
    private var held: (signIn: SignIn, value: Value)?

    init(empty: Value) {
        self.empty = empty
    }

    var value: Value {
        guard let held, held.signIn.isCurrent else { return empty }
        return held.value
    }

    mutating func set(_ value: Value, for signIn: SignIn) {
        guard signIn.isCurrent else { return }
        held = (signIn, value)
    }
}

extension SignInBound: Sendable where Value: Sendable {}
