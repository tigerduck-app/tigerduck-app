import Foundation
import Observation

/// When the library page asks for a new code: on a fixed interval while codes arrive, after a
/// growing pause once requests fail, and the seconds the shown code has left.
@Observable
final class LibraryCodeCycle {
    var countdown = 30

    @ObservationIgnored var fetchCode: @MainActor () async throws -> String = { try await LibraryAccount.code() }
    @ObservationIgnored var backoffSchedule: [TimeInterval] = [60, 120, 300]
    @ObservationIgnored var refreshInterval: TimeInterval = 30
    @ObservationIgnored private var refreshTimer: Timer?
    @ObservationIgnored private var countdownTimer: Timer?
    @ObservationIgnored private var consecutiveErrors = 0

    var isScheduled: Bool { refreshTimer != nil }

    /// Runs `action` after `interval`, again every interval when `repeats`, in place of what was due.
    func schedule(after interval: TimeInterval, repeats: Bool = false, _ action: @escaping () -> Void) {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in action() }
    }

    func cancelSchedule() {
        refreshTimer?.invalidate()
    }

    func noteSuccess() {
        consecutiveErrors = 0
    }

    /// The pause before the next request, longer for each failure in a row.
    func noteFailure() -> TimeInterval {
        consecutiveErrors += 1
        return backoffSchedule[max(0, min(consecutiveErrors - 1, backoffSchedule.count - 1))]
    }

    /// Counts the shown code down from `seconds` and calls `expired` once it reaches zero.
    func restartCountdown(from seconds: Int, expired: @escaping @MainActor () -> Void) {
        countdown = seconds
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                if self.countdown > 0 {
                    self.countdown -= 1
                } else {
                    expired()
                }
            }
        }
    }

    func stopCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = nil
    }

    func stop() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        stopCountdown()
    }
}
