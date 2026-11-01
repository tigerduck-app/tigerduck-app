import Foundation

nonisolated struct RosterRequestLog: Sendable {
    static let retryInterval: TimeInterval = 3600
    private var asked: [String: (signIn: AccountSession.Ticket, at: Date)] = [:]

    mutating func termsToAsk(in snapshot: [String: Any], signIn: AccountSession.Ticket, now: Date) -> [String] {
        let due = Set(snapshot["roster_requests"] as? [String] ?? []).filter { term in
            guard let last = asked[term], last.signIn == signIn else { return true }
            return now.timeIntervalSince(last.at) >= Self.retryInterval || now < last.at
        }
        for term in due { asked[term] = (signIn, now) }
        return due.sorted()
    }
}
