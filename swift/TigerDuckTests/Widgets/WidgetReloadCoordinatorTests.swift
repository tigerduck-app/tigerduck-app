import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WidgetReloadCoordinatorTests {
    final class FakeReloader: WidgetReloadCoordinator.Reloader {
        var callCount = 0
        func reloadAllTimelines() { callCount += 1 }
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
