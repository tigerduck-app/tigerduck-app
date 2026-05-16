import Testing
import Foundation
@testable import TigerDuck

@MainActor
struct AppClockTests {

    init() {
        UserDefaults(suiteName: AppClock.appGroupSuiteName)?
            .removeObject(forKey: AppClock.persistenceKey)
        AppClock._resetForTests()
    }

    // MARK: - now()

    @Test func nowReturnsRealDateWhenNoOverride() {
        let before = Date()
        let now = AppClock.now()
        let after = Date()
        #expect(now >= before)
        #expect(now <= after)
    }

    @Test func nowReturnsFrozenInstantWhenFrozenOverrideActive() {
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        AppClock.setOverride(ClockOverride(instant: fake, frozen: true, savedAtReal: Date()))
        #expect(AppClock.now() == fake)
    }

    @Test func nowAdvancesUnderTickingOverride() throws {
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        AppClock.setOverride(ClockOverride(instant: fake, frozen: false, savedAtReal: Date()))
        let first = AppClock.now()
        Thread.sleep(forTimeInterval: 0.05)
        let second = AppClock.now()
        #expect(first >= fake)
        #expect(second > first)
    }

    @Test func setOverrideNilRestoresRealClock() {
        AppClock.setOverride(ClockOverride(instant: Date(timeIntervalSince1970: 0), frozen: true, savedAtReal: Date()))
        AppClock.setOverride(nil)
        let now = AppClock.now()
        #expect(abs(now.timeIntervalSinceNow) < 1.0)
    }

    @Test func currentOverrideReflectsLastSetValue() {
        let override = ClockOverride(instant: Date(timeIntervalSince1970: 1), frozen: true, savedAtReal: Date())
        AppClock.setOverride(override)
        #expect(AppClock.currentOverride() == override)
    }

    // MARK: - Observers

    @Test func versionIncrementsOnEachSetOverride() {
        let v1 = AppClock.version()
        AppClock.setOverride(ClockOverride(instant: Date(), frozen: true, savedAtReal: Date()))
        let v2 = AppClock.version()
        AppClock.setOverride(nil)
        let v3 = AppClock.version()
        #expect(v2 > v1)
        #expect(v3 > v2)
    }

    @Test func observerFiresWithNewVersionOnSetOverride() {
        var received: [UInt64] = []
        let token = AppClock.observe { v in received.append(v) }
        defer { AppClock.removeObserver(token) }

        let before = AppClock.version()
        AppClock.setOverride(ClockOverride(instant: Date(), frozen: true, savedAtReal: Date()))
        AppClock.setOverride(nil)

        #expect(received.count == 2)
        #expect(received.allSatisfy { $0 > before })
    }

    @Test func removeObserverStopsCallbacks() {
        var fired = 0
        let token = AppClock.observe { _ in fired += 1 }
        AppClock.removeObserver(token)
        AppClock.setOverride(ClockOverride(instant: Date(), frozen: true, savedAtReal: Date()))
        AppClock.setOverride(nil)
        #expect(fired == 0)
    }

    // MARK: - Persistence

    @Test func readsPersistedOverrideFromAppGroupOnFirstAccess() throws {
        let suite = UserDefaults(suiteName: AppClock.appGroupSuiteName)!
        let override = ClockOverride(
            instant: Date(timeIntervalSince1970: 1_700_000_000),
            frozen: true,
            savedAtReal: Date()
        )
        suite.set(try JSONEncoder().encode(override), forKey: AppClock.persistenceKey)
        AppClock._resetForTests()
        #expect(AppClock.currentOverride() == override)
        suite.removeObject(forKey: AppClock.persistenceKey)
    }
}
