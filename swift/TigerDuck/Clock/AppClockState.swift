import Foundation
import Observation

/// Observable mirror of `AppClock`'s override version. Views and view models
/// that derive state from `AppClock.now()` cannot otherwise see an override
/// change: `AppClock` is an enum, and Observation only tracks classes.
///
/// Read `AppClockState.shared.version` in the dependency graph, in a computed
/// property the body calls or as `let _ = AppClockState.shared.version` at the
/// top of `body`, and SwiftUI re-evaluates when the override changes. In Release
/// `version` never changes (no `DebugClockController`); the cost is one subscription.
@MainActor
@Observable
final class AppClockState {
    static let shared = AppClockState()

    private(set) var version: UInt64 = AppClock.version()
    private var token: AppClock.ObserverToken?

    private init() {
        // The observer runs on the thread that called `AppClock.setOverride`, in
        // practice MainActor but not promised, so hop to MainActor before
        // touching @Observable state (Swift 6 strict concurrency).
        token = AppClock.observe { [weak self] v in
            Task { @MainActor [weak self] in
                self?.version = v
            }
        }
    }
}
