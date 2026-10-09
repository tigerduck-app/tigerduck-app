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
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { _ in await timer.sleep() })
        for _ in 0..<5 { coordinator.requestReload() }
        await timer.waitUntilArmed(atLeast: 5)
        #expect(fake.callCount == 0)
        // Every request's window ends at once; only the one no later request cancelled reloads.
        await timer.fire()
        try await waitUntil { fake.callCount >= 1 }
        #expect(fake.callCount == 1)
    }

    @Test func fires_oncePerWindow() async throws {
        let fake = FakeReloader()
        let timer = ManualSleeper()
        let coordinator = WidgetReloadCoordinator(reloader: fake, sleep: { _ in await timer.sleep() })
        coordinator.requestReload()
        await timer.waitUntilArmed()
        await timer.fire()
        try await waitUntil { fake.callCount == 1 }
        coordinator.requestReload()
        await timer.waitUntilArmed(atLeast: 2)
        await timer.fire()
        try await waitUntil { fake.callCount == 2 }
    }
}
