import Foundation
#if canImport(WidgetKit)
import WidgetKit
#endif

@MainActor
final class WidgetReloadCoordinator {
    protocol Reloader {
        func reloadAllTimelines()
    }

    struct WidgetKitReloader: Reloader {
        func reloadAllTimelines() {
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    private let reloader: Reloader
    private let debounce: TimeInterval
    private var pendingTask: Task<Void, Never>?

    init(reloader: Reloader = WidgetKitReloader(), debounceMs: Int = 300) {
        self.reloader = reloader
        self.debounce = TimeInterval(debounceMs) / 1000.0
    }

    func requestReload() {
        pendingTask?.cancel()
        let interval = debounce
        let reloader = reloader
        pendingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            reloader.reloadAllTimelines()
        }
    }
}
