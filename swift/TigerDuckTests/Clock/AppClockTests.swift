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

    // MARK: - realTime(forApp:)

    @Test func realTimeForAppIsIdentityWhenNoOverride() {
        let target = Date(timeIntervalSinceNow: 60)
        #expect(AppClock.realTime(forApp: target) == target)
    }

    @Test func realTimeForApp_frozen_translatesByDeltaFromInstant() {
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        AppClock.setOverride(ClockOverride(instant: fake, frozen: true, savedAtReal: Date()))
        let appTarget = fake.addingTimeInterval(90)
        let realTarget = AppClock.realTime(forApp: appTarget)
        // realTarget should be ~90s after real-now
        #expect(realTarget.timeIntervalSinceNow > 89)
        #expect(realTarget.timeIntervalSinceNow < 91)
    }

    @Test func realTimeForApp_ticking_translatesByOffset() {
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        AppClock.setOverride(ClockOverride(instant: fake, frozen: false, savedAtReal: savedAt))
        // offset = instant - savedAtReal = -100_000_000
        // realTime(appWall) = appWall - offset = appWall + 100_000_000
        let appTarget = fake.addingTimeInterval(60)
        let realTarget = AppClock.realTime(forApp: appTarget)
        let expected = appTarget.addingTimeInterval(100_000_000)
        #expect(abs(realTarget.timeIntervalSince(expected)) < 0.001)
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
