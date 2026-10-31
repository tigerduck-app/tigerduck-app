import Defaults
import Foundation

/// How long an automatic sign-in with a stored password waits after the school's or the
/// library's last refusal of it: each refusal counts toward the account's lockout. A sign-in the
/// user types is never held back. Each account keeps its count and time under its own keys.
nonisolated struct StoredPasswordBackoff: Sendable {
    static let ntust = StoredPasswordBackoff(count: .ntustStoredPasswordRefusals, last: .ntustStoredPasswordRefusedAt)
    static let library = StoredPasswordBackoff(
        count: .libraryStoredPasswordRefusals, last: .libraryStoredPasswordRefusedAt
    )

    static let quickRetries: [TimeInterval] = [10, 60, 5 * 60]
    static let retryInterval: TimeInterval = 6 * 60 * 60

    private let count: Defaults.Key<Int>
    private let last: Defaults.Key<Date?>

    private init(count: Defaults.Key<Int>, last: Defaults.Key<Date?>) {
        self.count = count
        self.last = last
    }

    var refusals: (count: Int, last: Date?) {
        get { (Defaults[count], Defaults[last]) }
        nonmutating set {
            Defaults[count] = newValue.count
            Defaults[last] = newValue.last
        }
    }

    static func retryDelay(afterRefusals refusals: Int) -> TimeInterval {
        refusals > quickRetries.count ? retryInterval : quickRetries[max(refusals, 1) - 1]
    }

    static func retryAt(refusals: Int, lastRefusal: Date?, now: Date) -> Date? {
        guard refusals > 0 else { return nil }
        guard let lastRefusal, lastRefusal <= now else { return now }
        return lastRefusal.addingTimeInterval(retryDelay(afterRefusals: refusals))
    }

    func retryAt(now: Date) -> Date? {
        let refusals = refusals
        return Self.retryAt(refusals: refusals.count, lastRefusal: refusals.last, now: now)
    }

    func postIsDue(now: Date) -> Bool {
        retryAt(now: now).map { $0 <= now } ?? true
    }

    /// Returns when the next post is due.
    @discardableResult
    func noteRefused(at now: Date) -> Date {
        let count = refusals.count + 1
        refusals = (count, now)
        return now.addingTimeInterval(Self.retryDelay(afterRefusals: count))
    }

    func forget() {
        refusals = (0, nil)
    }
}
