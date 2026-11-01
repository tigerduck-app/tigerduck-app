import Foundation

nonisolated struct FreshnessPolicy: Equatable, Sendable {
    let lifetime: TimeInterval

    func isFresh(storedAt: Date, now: Date = Date()) -> Bool {
        now.timeIntervalSince(storedAt) < lifetime
    }
}

nonisolated struct CachedValue<Value> {
    let value: Value
    let storedAt: Date

    func fresh(under policy: FreshnessPolicy, now: Date = Date()) -> Value? {
        policy.isFresh(storedAt: storedAt, now: now) ? value : nil
    }
}

extension CachedValue: Sendable where Value: Sendable {}
