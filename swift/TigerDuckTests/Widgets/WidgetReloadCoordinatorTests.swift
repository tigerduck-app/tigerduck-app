import Foundation
import Testing
import os
@testable import TigerDuck

@MainActor
struct WidgetReloadCoordinatorTests {
    final class FakeReloader: WidgetReloadCoordinator.Reloader {
        // `Reloader` is Sendable and the debounce calls back off the main
        // actor, so the counter cannot be a plain `var` — that is a warning
        // today and an error in the Swift 6 language mode.
        private let count = OSAllocatedUnfairLock(initialState: 0)
        var callCount: Int { count.withLock { $0 } }
        func reloadAllTimelines() { count.withLock { $0 += 1 } }
    }

    // The debounce wait is a `ManualSleeper`, so a window ends when the test fires it: on a
    // loaded runner a real one can take far longer to end, and a second request made before
    // it ends cancels it, so a correct coordinator would read as broken.

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
        // Each request cancelled the window before it, which ends that wait; firing ends the last.
        // Counting once every window has finished leaves no late reload unseen.
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

    /// A sync trigger's handler answers next, and iOS may suspend the app before the debounce
    /// ends (https://github.com/tigerduck-app/tigerduck-app/issues/664).
    @Test func reloadNowIfPending_sendsAWaitingReloadAtOnce_andOnlyOnce() async throws {
        let fake = FakeReloader()
        let timer = ManualSleeper()
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { await timer.sleep(for: $0) })
        coordinator.requestReload()
        let window = try #require(coordinator.pendingTask)

        coordinator.reloadNowIfPending()
        #expect(fake.callCount == 1)

        // The window it cut short ends without a reload of its own, and nothing waits any more.
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
