import Defaults
import Foundation

nonisolated struct StoredPasswordLockoutBackoff: Sendable {
    static var ntust: StoredPasswordLockoutBackoff {
        StoredPasswordLockoutBackoff(count: .ntustStoredPasswordRefusals, last: .ntustStoredPasswordRefusedAt)
    }

    static var library: StoredPasswordLockoutBackoff {
        StoredPasswordLockoutBackoff(count: .libraryStoredPasswordRefusals, last: .libraryStoredPasswordRefusedAt)
    }

    static let quickRetries: [TimeInterval] = [10, 60, 5 * 60]
    static let retryInterval: TimeInterval = 6 * 60 * 60

    private let count: AccountKey<Int>
    private let last: AccountKey<Date?>

    private init(count: AccountKey<Int>, last: AccountKey<Date?>) {
        self.count = count
        self.last = last
    }

    var refusals: (count: Int, last: Date?) { (Defaults[count], Defaults[last]) }

    func setRefusals(_ refusals: (count: Int, last: Date?), for signIn: SignIn) {
        Defaults[count, for: signIn] = refusals.count
        Defaults[last, for: signIn] = refusals.last
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

    @discardableResult
    func recordRefusalAndNextPost(at now: Date, for signIn: SignIn) -> Date {
        let count = refusals.count + 1
        setRefusals((count, now), for: signIn)
        return now.addingTimeInterval(Self.retryDelay(afterRefusals: count))
    }

    func forget() {
        Defaults.reset(count, last)
    }
}
