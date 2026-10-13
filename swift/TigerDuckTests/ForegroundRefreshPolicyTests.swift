import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ForegroundRefreshPolicyTests {
    private func isDue(synced: TimeInterval?, attempted: TimeInterval?) -> Bool {
        let now = Date()
        return AppServiceBridge.isForegroundRefreshDue(
            syncedAt: synced.map { now - $0 },
            lastAttempt: attempted.map { now - $0 },
            now: now
        )
    }

    @Test("a return refreshes data that is a minute old, or was never synced")
    func dueByAge() {
        #expect(isDue(synced: nil, attempted: nil))
        #expect(!isDue(synced: 30, attempted: nil))
        #expect(isDue(synced: 61, attempted: nil))
    }

    @Test("a failed attempt holds the next one off for a minute")
    func failedAttemptsBackOff() {
        #expect(!isDue(synced: 600, attempted: 30))
        #expect(isDue(synced: 600, attempted: 61))
    }

    @Test("a stamp ahead of the clock does not block the refresh")
    func clockSetBack() {
        #expect(isDue(synced: -3600, attempted: nil))
    }
}
