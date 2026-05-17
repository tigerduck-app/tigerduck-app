#if DEBUG
import Foundation
import WidgetKit
import os.log

/// Orchestrates the debug clock override: persistence, `AppClock` update,
/// and cross-process fanout (widgets, LiveActivity, watch).
///
/// Entirely `#if DEBUG`-gated. In Release builds this file is not
/// compiled, so a stale App Group override key from a prior Debug install
/// of the same bundle ID cannot bleed into a production app.
@MainActor
final class DebugClockController {

    static let shared = DebugClockController()

    /// Posted after `setOverride` so view models that already subscribe to
    /// `NotificationCenter` can recompute "now"-derived state. View models
    /// can equivalently use `AppClock.observe` — pick whichever matches the
    /// surrounding pattern.
    static let didChangeNotification = Notification.Name("AppClockDidChange")

    private let store = DebugClockStore()
    private let log = Logger(subsystem: "org.ntust.app.TigerDuck", category: "DebugClock")

    private init() {}

    /// Loads any persisted override into `AppClock`. Call once from
    /// `TigerDuckApp.init` (inside `#if DEBUG`) before any UI reads the clock.
    func bootstrap() {
        guard let persisted = store.load() else { return }
        AppClock.setOverride(persisted)
        log.debug("Bootstrapped clock override: frozen=\(persisted.frozen, privacy: .public)")
    }

    func setOverride(_ override: ClockOverride?) {
        if let override {
            store.save(override)
        } else {
            store.clear()
        }
        AppClock.setOverride(override)

        // Widget process re-reads the App Group on its next timeline build.
        WidgetCenter.shared.reloadAllTimelines()

        // LiveActivity refresh + reminder rescheduling + watch push are
        // wired in by later migration tasks once those subsystems are
        // reading through AppClock.

        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        log.debug("setOverride applied; active=\(override != nil, privacy: .public)")
    }

    func currentOverride() -> ClockOverride? {
        AppClock.currentOverride()
    }
}
#endif
