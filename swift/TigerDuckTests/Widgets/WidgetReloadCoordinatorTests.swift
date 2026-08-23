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

    @Test func collapses_rapidCalls_intoOne() async throws {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake, debounceMs: 50)
        for _ in 0..<5 { coordinator.requestReload() }
        try await Task.sleep(for: .milliseconds(120))
        #expect(fake.callCount == 1)
    }

    @Test func fires_oncePerWindow() async throws {
        let fake = FakeReloader()
        let coordinator = WidgetReloadCoordinator(reloader: fake, debounceMs: 50)
        coordinator.requestReload()
        try await Task.sleep(for: .milliseconds(120))
        coordinator.requestReload()
        try await Task.sleep(for: .milliseconds(120))
        #expect(fake.callCount == 2)
    }
}
