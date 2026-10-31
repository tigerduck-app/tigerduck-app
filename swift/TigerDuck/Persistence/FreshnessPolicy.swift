import Foundation

/// How long a cached answer stands in for asking again: it is fresh while its age is under the
/// lifetime.
nonisolated struct FreshnessPolicy: Equatable, Sendable {
    let lifetime: TimeInterval

    func isFresh(storedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(storedAt) < lifetime
    }
}

/// A cached value and when it was stored.
nonisolated struct CachedValue<Value> {
    let value: Value
    let storedAt: Date

    /// The value while `policy` holds it fresh, else nil.
    func fresh(under policy: FreshnessPolicy, now: Date = Date()) -> Value? {
        policy.isFresh(storedAt: storedAt, now: now) ? value : nil
    }
}

extension CachedValue: Sendable where Value: Sendable {}
