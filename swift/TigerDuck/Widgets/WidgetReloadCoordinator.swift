import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class WidgetReloadCoordinator {
    nonisolated protocol Reloader: Sendable {
        func reloadAllTimelines()
    }

    nonisolated struct WidgetKitReloader: Reloader {
        func reloadAllTimelines() {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    nonisolated private let reloader: Reloader
    nonisolated private let debounce: TimeInterval
    /// The debounce wait, injectable so a test can end it by hand instead of sleeping through it.
    nonisolated private let sleep: @Sendable (Duration) async -> Void
    private var pendingTask: Task<Void, Never>?

    nonisolated init(
        reloader: Reloader = WidgetKitReloader(),
        debounceMs: Int = 300,
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.reloader = reloader
        self.debounce = TimeInterval(debounceMs) / 1000.0
        self.sleep = sleep
    }

    func requestReload() {
        pendingTask?.cancel()
        let interval = debounce
        let reloader = reloader
        let sleep = self.sleep
        pendingTask = Task { @MainActor in
            await sleep(.seconds(interval))
            guard !Task.isCancelled else { return }
            reloader.reloadAllTimelines()
        }
    }
}
