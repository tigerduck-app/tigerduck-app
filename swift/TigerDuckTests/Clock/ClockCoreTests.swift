import Testing
import Foundation
@testable import TigerDuck

struct ClockCoreTests {

    private func makeCore() -> ClockCore {
        ClockCore(persistedStore: nil, persistenceKey: AppClock.persistenceKey)
    }

    private func override(
        _ instant: Date,
        frozen: Bool,
        savedAtReal: Date = Date()
    ) -> ClockOverride {
        ClockOverride(instant: instant, frozen: frozen, savedAtReal: savedAtReal)
    }

    @Test func nowReturnsRealDateWhenNoOverride() {
        let core = makeCore()
        let before = Date()
        let now = core.now()
        let after = Date()
        #expect(now >= before)
        #expect(now <= after)
    }

    @Test func nowReturnsFrozenInstantWhenFrozenOverrideActive() {
        let core = makeCore()
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        core.setOverride(override(fake, frozen: true))
        #expect(core.now() == fake)
    }

    @Test func nowAdvancesUnderTickingOverride() async throws {
        let core = makeCore()
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        core.setOverride(override(fake, frozen: false))
        let first = core.now()
        #expect(first >= fake)
        try await waitUntil { core.now() > first }
    }

    @Test func setOverrideNilRestoresRealClock() {
        let core = makeCore()
        core.setOverride(override(Date(timeIntervalSince1970: 0), frozen: true))
        core.setOverride(nil)
        let now = core.now()
        #expect(abs(now.timeIntervalSinceNow) < 1.0)
    }

    @Test func currentOverrideReflectsLastSetValue() {
        let core = makeCore()
        let value = override(Date(timeIntervalSince1970: 1), frozen: true)
        core.setOverride(value)
        #expect(core.currentOverride() == value)
    }

    @Test func realTimeForAppIsIdentityWhenNoOverride() {
        let core = makeCore()
        let target = Date(timeIntervalSinceNow: 60)
        #expect(core.realTime(forApp: target) == target)
    }

    @Test func realTimeForApp_frozen_translatesByDeltaFromInstant() {
        let core = makeCore()
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        core.setOverride(override(fake, frozen: true))
        let appTarget = fake.addingTimeInterval(90)
        let realTarget = core.realTime(forApp: appTarget)
        #expect(realTarget.timeIntervalSinceNow > 89)
        #expect(realTarget.timeIntervalSinceNow < 91)
    }

    @Test func realTimeForApp_ticking_translatesByOffset() {
        let core = makeCore()
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        core.setOverride(override(fake, frozen: false, savedAtReal: savedAt))
        let appTarget = fake.addingTimeInterval(60)
        let realTarget = core.realTime(forApp: appTarget)
        let expected = appTarget.addingTimeInterval(100_000_000)
        #expect(abs(realTarget.timeIntervalSince(expected)) < 0.001)
    }

    @Test func versionIncrementsOnEachSetOverride() {
        let core = makeCore()
        let v1 = core.version()
        core.setOverride(override(Date(), frozen: true))
        let v2 = core.version()
        core.setOverride(nil)
        let v3 = core.version()
        #expect(v2 > v1)
        #expect(v3 > v2)
    }

    @Test func observerFiresWithNewVersionOnSetOverride() {
        let core = makeCore()
        let received = Received()
        let token = core.observe { received.append($0) }
        defer { core.removeObserver(token) }

        let before = core.version()
        core.setOverride(override(Date(), frozen: true))
        core.setOverride(nil)

        #expect(received.values.count == 2)
        #expect(received.values.allSatisfy { $0 > before })
    }

    @Test func removeObserverStopsCallbacks() {
        let core = makeCore()
        let received = Received()
        let token = core.observe { received.append($0) }
        core.removeObserver(token)
        core.setOverride(override(Date(), frozen: true))
        core.setOverride(nil)
        #expect(received.values.isEmpty)
    }

    private final class Received {
        private(set) var values: [UInt64] = []
        func append(_ v: UInt64) { values.append(v) }
    }

    @Test func readsPersistedOverrideOnFirstAccess() throws {
        let suiteName = "ClockCoreTests.readsPersisted"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        let value = override(Date(timeIntervalSince1970: 1_700_000_000), frozen: true)
        store.set(try JSONEncoder().encode(value), forKey: AppClock.persistenceKey)

        let core = ClockCore(persistedStore: store, persistenceKey: AppClock.persistenceKey)
        #expect(core.currentOverride() == value)
    }

    @Test func nilStoreNeverReadsPersistedOverride() throws {
        let suiteName = "ClockCoreTests.nilStore"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        let value = override(Date(timeIntervalSince1970: 1_700_000_000), frozen: true)
        store.set(try JSONEncoder().encode(value), forKey: AppClock.persistenceKey)

        let core = ClockCore(persistedStore: nil, persistenceKey: AppClock.persistenceKey)
        #expect(core.currentOverride() == nil)
    }

    @Test func setOverrideWinsOverThePersistedValue() throws {
        let suiteName = "ClockCoreTests.setBeatsPersisted"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        let persisted = override(Date(timeIntervalSince1970: 1_700_000_000), frozen: true)
        store.set(try JSONEncoder().encode(persisted), forKey: AppClock.persistenceKey)

        let core = ClockCore(persistedStore: store, persistenceKey: AppClock.persistenceKey)
        core.setOverride(nil)
        #expect(core.currentOverride() == nil)
    }
}
