import Foundation
import Observation

/// Observable mirror of `AppClock`'s override version. Views or view
/// models that derive state from `AppClock.now()` (greetings, "today's
/// courses", weekday filters) cannot otherwise see a debug override flip
/// because `AppClock` is an enum — Observation tracking is class-only.
///
/// Read `AppClockState.shared.version` somewhere in the dependency graph
/// (inside a computed property the view body invokes, or as `let _ =
/// AppClockState.shared.version` at the top of `body`) and SwiftUI will
/// re-evaluate the body whenever the override changes.
///
/// In Release builds there is no `DebugClockController`, so `version`
/// stays at its bootstrap value forever — zero runtime cost beyond the
/// single subscription.
@MainActor
@Observable
final class AppClockState {
    static let shared = AppClockState()

    private(set) var version: UInt64 = AppClock.version()
    private var token: AppClock.ObserverToken?

    private init() {
        // The observer block fires on whoever's thread called
        // `AppClock.setOverride` (in practice MainActor, but the API
        // doesn't promise it). Hop to MainActor before touching
        // @Observable state to keep Swift 6 strict-concurrency happy.
        token = AppClock.observe { [weak self] v in
            Task { @MainActor [weak self] in
                self?.version = v
            }
        }
    }
}
