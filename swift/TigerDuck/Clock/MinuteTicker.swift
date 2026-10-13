import Foundation
import Observation

/// Observable minute pulse that class-table and today-card views use to
/// re-derive minute-of-day state without a Combine publisher. Reading `tick`
/// in a view-model getter creates an Observation dependency, and the timer
/// bumps it on the main actor so SwiftUI re-evaluates the body.
///
/// Checks every 5 seconds, like Android's poll in `ClassTableViewModel`, so the
/// "Current class" card changes within seconds of the minute boundary, not a
/// minute late. `tick` moves only when the minute does: its readers show minutes.
@MainActor
@Observable
final class MinuteTicker {
    private(set) var tick: UInt64 = 0

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastMinute: Int64
    private let now: () -> Date

    init(interval: TimeInterval = 5, now: @escaping () -> Date = { AppClock.now() }) {
        self.now = now
        lastMinute = Self.minute(of: now())
        // Tolerance gives the system room to coalesce wakeups with
        // other timers — we don't need millisecond precision; the goal
        // is "within a few seconds of the minute boundary".
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            // Re-capture weakly inside the Task closure so Swift 6 strict
            // concurrency doesn't complain about a strong self leaking
            // through the @MainActor hop.
            Task { @MainActor [weak self] in self?.advanceIfMinuteChanged() }
        }
        t.tolerance = 1
        timer = t
    }

    deinit {
        timer?.invalidate()
    }

    func advanceIfMinuteChanged() {
        let minute = Self.minute(of: now())
        guard minute != lastMinute else { return }
        lastMinute = minute
        tick &+= 1
    }

    /// Whole minutes since the epoch. Every time zone's offset is whole minutes,
    /// so this changes on Taipei's minute boundaries as well.
    private static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}
