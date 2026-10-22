import Foundation
import Testing
import os
@testable import TigerDuck

@MainActor
struct WidgetReloadCoordinatorTests {
    final class FakeReloader: WidgetReloadCoordinator.Reloader {
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var callCount: Int { count.withLock { $0 } }
        func reloadAllTimelines() { count.withLock { $0 += 1 } }
    }

    @Test func collapses_rapidCalls_intoOne() async throws {
        let fake = FakeReloader()
        let timer = ManualSleeper()
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { await timer.sleep(for: $0) })
        var windows: [Task<Void, Never>] = []
        for _ in 0..<5 {
            coordinator.requestReload()
            windows.append(try #require(coordinator.pendingTask))
        }
        try await timer.waitUntilArmed(atLeast: 5)
        #expect(await timer.requestedDurations == [Duration](repeating: .milliseconds(300), count: 5))
        #expect(fake.callCount == 0)
        await timer.fire()
        for window in windows { await window.value }
        #expect(fake.callCount == 1)
    }

    @Test func fires_oncePerWindow() async throws {
        let fake = FakeReloader()
        let timer = ManualSleeper()
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { await timer.sleep(for: $0) })
        coordinator.requestReload()
        try await timer.waitUntilArmed()
        await timer.fire()
        try await waitUntil { fake.callCount == 1 }
        coordinator.requestReload()
        try await timer.waitUntilArmed(atLeast: 2)
        #expect(await timer.requestedDurations == [.milliseconds(300), .milliseconds(300)])
        await timer.fire()
        try await waitUntil { fake.callCount == 2 }
    }

    @Test func reloadNowIfPending_sendsAWaitingReloadAtOnce_andOnlyOnce() async throws {
        let fake = FakeReloader()
        let timer = ManualSleeper()
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { await timer.sleep(for: $0) })
        coordinator.requestReload()
        let window = try #require(coordinator.pendingTask)

        coordinator.reloadNowIfPending()
        #expect(fake.callCount == 1)

        try await timer.waitUntilArmed()
        await timer.fire()
        await window.value
        coordinator.reloadNowIfPending()
        #expect(fake.callCount == 1)
    }

    @Test func reloadNowIfPending_afterTheDebounceReloaded_sendsNothing() async throws {
        let fake = FakeReloader()
        let timer = ManualSleeper()
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { await timer.sleep(for: $0) })
        coordinator.requestReload()
        try await timer.waitUntilArmed()
        await timer.fire()
        try await waitUntil { fake.callCount == 1 }

        coordinator.reloadNowIfPending()

        #expect(fake.callCount == 1)
    }

    @Test func reloadNowIfPending_withNothingAsked_sendsNothing() {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake)

        coordinator.reloadNowIfPending()

        #expect(fake.callCount == 0)
    }
}
