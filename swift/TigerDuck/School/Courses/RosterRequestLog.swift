import Foundation

/// When each term's roster request last went to the school. A request stays until a roster
/// arrives, so while course selection does not answer, a term is asked again after an hour, not
/// on every full sync.
nonisolated struct RosterRequestLog: Sendable {
    static let retryInterval: TimeInterval = 3600
    private var asked: [String: (signIn: AccountSession.Ticket, at: Date)] = [:]

    /// The terms of the snapshot's `roster_requests` to ask now, recorded as asked. A snapshot
    /// without the key, from a backend that predates it, requests nothing.
    mutating func termsToAsk(in snapshot: [String: Any], signIn: AccountSession.Ticket, now: Date) -> [String] {
        let due = Set(snapshot["roster_requests"] as? [String] ?? []).filter { term in
            guard let last = asked[term], last.signIn == signIn else { return true }
            return now.timeIntervalSince(last.at) >= Self.retryInterval || now < last.at
        }
        for term in due { asked[term] = (signIn, now) }
        return due.sorted()
    }
}
