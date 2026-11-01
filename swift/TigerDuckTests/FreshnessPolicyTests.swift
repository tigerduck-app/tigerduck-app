import Foundation
import Testing
@testable import TigerDuck

struct FreshnessPolicyTests {
    @Test("a cached answer is fresh until its lifetime has passed")
    func freshUntilTheLifetimePasses() {
        let stored = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let policy = FreshnessPolicy(lifetime: 60)

        #expect(policy.isFresh(storedAt: stored, now: stored.addingTimeInterval(59)))
        #expect(!policy.isFresh(storedAt: stored, now: stored.addingTimeInterval(60)))
        #expect(CachedValue(value: 1, storedAt: stored).fresh(under: policy, now: stored.addingTimeInterval(30)) == 1)
        #expect(CachedValue(value: 1, storedAt: stored).fresh(under: policy, now: stored.addingTimeInterval(61)) == nil)
    }
}
