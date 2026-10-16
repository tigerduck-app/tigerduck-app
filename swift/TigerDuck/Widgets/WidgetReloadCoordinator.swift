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
    private(set) var pendingTask: Task<Void, Never>?
    /// Whether `pendingTask` has yet to reload. A finished task is still held there.
    private var reloadIsDue = false

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
        reloadIsDue = true
        let interval = debounce
        let reloader = reloader
        let sleep = self.sleep
        pendingTask = Task { @MainActor [weak self] in
            await sleep(.seconds(interval))
            guard !Task.isCancelled else { return }
            self?.reloadIsDue = false
            reloader.reloadAllTimelines()
        }
    }

    /// Ends the debounce early: the reload it waits for goes out now. Nothing goes out when none waits.
    func reloadNowIfPending() {
        guard reloadIsDue else { return }
        reloadIsDue = false
        pendingTask?.cancel()
        reloader.reloadAllTimelines()
    }
}
