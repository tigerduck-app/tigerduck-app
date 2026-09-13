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

    // Waits on the reload count rather than on fixed sleeps: on a loaded runner
    // a 50 ms debounce can take far longer than 120 ms to fire, and a second
    // request made before it fires cancels it — a correct coordinator then
    // reads as broken.

    @Test func collapses_rapidCalls_intoOne() async throws {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake, debounceMs: 50)
        for _ in 0..<5 { coordinator.requestReload() }
        try await waitUntil { fake.callCount >= 1 }
        // Several more debounce windows: long enough for any request that was
        // not collapsed to have fired as well.
        try await Task.sleep(for: .milliseconds(200))
        #expect(fake.callCount == 1)
    }

    @Test func fires_oncePerWindow() async throws {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake, debounceMs: 50)
        coordinator.requestReload()
        try await waitUntil { fake.callCount == 1 }
        coordinator.requestReload()
        try await waitUntil { fake.callCount == 2 }
    }
}
