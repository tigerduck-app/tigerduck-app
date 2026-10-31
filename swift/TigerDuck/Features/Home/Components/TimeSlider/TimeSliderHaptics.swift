import UIKit

/// A selection tick each time a drag of the slider crosses a step of
/// `TimeSliderMetrics.dragHapticIntervalMinutes`.
final class TimeSliderHaptics {
    private let generator = UISelectionFeedbackGenerator()
    private var lastStep = 0

    func prepare() {
        generator.prepare()
    }

    func start(at time: Date) {
        generator.prepare()
        lastStep = step(for: time)
    }

    func move(to time: Date) {
        let current = step(for: time)
        guard current != lastStep else { return }
        generator.selectionChanged()
        generator.prepare()
        lastStep = current
    }

    private func step(for time: Date) -> Int {
        let interval = TimeSliderMetrics.dragHapticIntervalMinutes * 60
        return Int(floor(time.timeIntervalSinceReferenceDate / interval))
    }
}
