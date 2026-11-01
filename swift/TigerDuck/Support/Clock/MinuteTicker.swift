import Foundation
import Observation

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
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
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

    private static func minute(of date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 / 60).rounded(.down))
    }
}
