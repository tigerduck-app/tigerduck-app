import Testing
import Foundation
@testable import TigerDuck

/// These drive their own `ClockCore` rather than the process-global
/// `AppClock`. That is deliberate and load-bearing: Swift Testing runs cases
/// in parallel, so when these tests froze the shared clock they also froze it
/// for whatever unrelated test happened to be running — `ScheduleSyncService`
/// once produced a fire time in 2082 because `setOverrideNilRestoresRealClock`
/// had briefly pinned the clock to 1970. Nothing below touches shared state,
/// so nothing below can do that again.
struct ClockCoreTests {

    /// A core with no persisted store: `nil` means "never read one", which is
    /// what release builds pass and what every test here wants except the
    /// persistence cases below.
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

    // MARK: - now()

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

    @Test func nowAdvancesUnderTickingOverride() throws {
        let core = makeCore()
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        core.setOverride(override(fake, frozen: false))
        let first = core.now()
        Thread.sleep(forTimeInterval: 0.05)
        let second = core.now()
        #expect(first >= fake)
        #expect(second > first)
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

    // MARK: - realTime(forApp:)

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
        // realTarget should be ~90s after real-now
        #expect(realTarget.timeIntervalSinceNow > 89)
        #expect(realTarget.timeIntervalSinceNow < 91)
    }

    @Test func realTimeForApp_ticking_translatesByOffset() {
        let core = makeCore()
        let fake = Date(timeIntervalSince1970: 1_700_000_000)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        core.setOverride(override(fake, frozen: false, savedAtReal: savedAt))
        // offset = instant - savedAtReal = -100_000_000
        // realTime(appWall) = appWall - offset = appWall + 100_000_000
        let appTarget = fake.addingTimeInterval(60)
        let realTarget = core.realTime(forApp: appTarget)
        let expected = appTarget.addingTimeInterval(100_000_000)
        #expect(abs(realTarget.timeIntervalSince(expected)) < 0.001)
    }

    // MARK: - Observers

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

    /// Observer callbacks run on whoever called `setOverride`, so the
    /// recording box has to be a reference the closure can capture rather
    /// than a local `var`.
    private final class Received {
        private(set) var values: [UInt64] = []
        func append(_ v: UInt64) { values.append(v) }
    }

    // MARK: - Persistence

    @Test func readsPersistedOverrideOnFirstAccess() throws {
        // A suite of this test's own: the App Group defaults the app uses are
        // as shared as the clock was, and writing to them would put the same
        // race back by another route.
        let suiteName = "ClockCoreTests.readsPersisted"
        let store = UserDefaults(suiteName: suiteName)!
        defer { store.removePersistentDomain(forName: suiteName) }

        let value = override(Date(timeIntervalSince1970: 1_700_000_000), frozen: true)
        store.set(try JSONEncoder().encode(value), forKey: AppClock.persistenceKey)

        let core = ClockCore(persistedStore: store, persistenceKey: AppClock.persistenceKey)
        #expect(core.currentOverride() == value)
    }

    @Test func nilStoreNeverReadsPersistedOverride() throws {
        // The release build passes nil so a stale override written by an
        // earlier debug or TestFlight build cannot follow the user into a
        // release install. Same key, same data, no override.
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
        // The lazy load must not resurrect the persisted value afterwards.
        #expect(core.currentOverride() == nil)
    }
}
