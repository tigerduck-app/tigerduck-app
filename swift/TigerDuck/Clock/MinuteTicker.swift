import Foundation
import Observation

/// Observable 5-second pulse used by class-table / today-card views to
/// re-derive minute-of-day state without listening on a Combine
/// publisher. Reading `tick` somewhere in a view-model getter creates
/// an Observation dependency; the timer increments `tick` on the main
/// actor so SwiftUI re-evaluates the dependent body.
///
/// Matches Android's 5-second poll in `ClassTableViewModel` so the
/// "Current class" card transitions within a few seconds of the
/// wall-clock minute boundary, not up to a minute later.
@MainActor
@Observable
final class MinuteTicker {
    private(set) var tick: UInt64 = 0

    @ObservationIgnored private var timer: Timer?

    init(interval: TimeInterval = 5) {
        // Tolerance gives the system room to coalesce wakeups with
        // other timers — we don't need millisecond precision; the goal
        // is "within a few seconds of the minute boundary".
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Re-capture weakly inside the Task closure so Swift 6 strict
            // concurrency doesn't complain about a strong self leaking
            // through the @MainActor hop.
            Task { @MainActor [weak self] in self?.tick &+= 1 }
        }
        t.tolerance = 1
        timer = t
    }

    deinit {
        timer?.invalidate()
    }
}
