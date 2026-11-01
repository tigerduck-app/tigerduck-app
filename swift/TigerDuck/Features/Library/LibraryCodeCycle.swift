import Foundation
import Observation

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

    func noteFailure() -> TimeInterval {
        consecutiveErrors += 1
        return backoffSchedule[max(0, min(consecutiveErrors - 1, backoffSchedule.count - 1))]
    }

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
