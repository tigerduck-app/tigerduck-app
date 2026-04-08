import SwiftUI
import UIKit

@Observable
final class TimeSliderViewModel {
    // MARK: - Data
    var timeSlots: [CourseTimeSlot] = []

    // MARK: - State
    var selectedTime: Date = Date()
    var isUserDragging: Bool = false

    // MARK: - Private
    private var autoReturnTask: Task<Void, Never>?
    private var allCourses: [SDCourse] = []
    private var timelineCenterDate: Date = Date()
    /// Tracks which haptic interval the user was last in, to fire once per crossing.
    private var lastHapticSlot: Int = 0
    private let hapticGenerator = UISelectionFeedbackGenerator()

    var hasCourses: Bool { !timeSlots.isEmpty }

    // MARK: - Compressed Position Cache

    /// Sorted anchors mapping each slot boundary to a compressed X position (in points).
    /// Built once per `configure` call; `xOffset(for:)` interpolates between them.
    private var anchors: [(time: Date, x: CGFloat)] = []

    init() {
        hapticGenerator.prepare()
    }

    // MARK: - Configuration

    func configure(courses: [SDCourse]) {
        allCourses = courses
        rebuildTimeline(around: Date())
        if !isUserDragging {
            selectedTime = Date()
        }
    }

    private func rebuildTimeline(around center: Date) {
        timelineCenterDate = center
        timeSlots = CourseTimeSlot.buildMultiDaySlots(
            from: allCourses,
            centerDate: center,
            dayRadius: TimeSliderMetrics.timelineDayRadius
        )
        rebuildAnchors()
    }

    /// Build a compressed mapping: real time → visual X position.
    /// Course blocks use linear density; gaps between courses are logarithmically compressed.
    private func rebuildAnchors() {
        guard !timeSlots.isEmpty else { anchors = []; return }

        let ppm = TimeSliderMetrics.pointsPerMinute
        let refMin = TimeSliderMetrics.logarithmicReferenceMinutes
        let minGap = TimeSliderMetrics.minimumGapPoints
        let maxGap = TimeSliderMetrics.maximumGapPoints
        let dayGap = TimeSliderMetrics.dayBoundaryGapPoints

        var result: [(time: Date, x: CGFloat)] = []
        var x: CGFloat = 0

        // Add padding before first slot
        let paddingBefore = compressedGapWidth(
            minutes: 60, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
        )
        result.append((time: timeSlots[0].start.addingTimeInterval(-3600), x: x))
        x += paddingBefore

        for (i, slot) in timeSlots.enumerated() {
            // Slot start
            result.append((time: slot.start, x: x))

            // Slot duration (linear)
            let durationMin = slot.end.timeIntervalSince(slot.start) / 60
            x += CGFloat(durationMin) * ppm

            // Slot end
            result.append((time: slot.end, x: x))

            // Gap to next slot
            if i + 1 < timeSlots.count {
                let next = timeSlots[i + 1]
                let gapMin = next.start.timeIntervalSince(slot.end) / 60

                let calendar = Calendar.current
                let crossesDay = !calendar.isDate(slot.date, inSameDayAs: next.date)

                if crossesDay {
                    x += dayGap
                } else {
                    x += compressedGapWidth(
                        minutes: gapMin, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
                    )
                }
            }
        }

        // Add padding after last slot
        let paddingAfter = compressedGapWidth(
            minutes: 60, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
        )
        x += paddingAfter
        if let last = timeSlots.last {
            result.append((time: last.end.addingTimeInterval(3600), x: x))
        }

        anchors = result
    }

    /// Compress a gap of `minutes` into a visual width.
    private func compressedGapWidth(
        minutes: Double, refMin: Double, ppm: CGFloat, minGap: CGFloat, maxGap: CGFloat
    ) -> CGFloat {
        guard minutes > 0 else { return minGap }
        let linear = CGFloat(minutes) * ppm
        let compressed = CGFloat(log(1 + minutes / refMin)) * ppm * CGFloat(refMin)
        let width = min(linear, compressed)
        return min(max(width, minGap), maxGap)
    }

    // MARK: - Real-time Update

    func tick(_ now: Date) {
        if !isUserDragging {
            selectedTime = now
        }
        checkTimelineRebuildNeeded()
    }

    private func checkTimelineRebuildNeeded() {
        let calendar = Calendar.current
        let daysSinceCenter = abs(calendar.dateComponents(
            [.day], from: timelineCenterDate, to: selectedTime
        ).day ?? 0)
        if daysSinceCenter >= TimeSliderMetrics.timelineDayRadius - TimeSliderMetrics.timelineRebuildTriggerDays {
            rebuildTimeline(around: selectedTime)
        }
    }

    // MARK: - Course State Resolution

    func courseState(at time: Date) -> CourseState {
        for slot in timeSlots {
            if time >= slot.start && time <= slot.end {
                return .inClass(slot)
            }
        }
        let previous = timeSlots.last { $0.end <= time }
        let next = timeSlots.first { $0.start > time }

        if previous == nil, let next {
            return .beforeFirst(next: next)
        }
        if let previous, next == nil {
            return .afterLast(previous: previous)
        }
        return .between(previous: previous, next: next)
    }

    var currentCourseState: CourseState {
        courseState(at: selectedTime)
    }

    // MARK: - Compressed X Offset

    /// Returns the compressed X position for a given time, relative to selectedTime's X.
    /// Positive = right (future), negative = left (past).
    func xOffset(for time: Date) -> CGFloat {
        let timeX = interpolateX(for: time)
        let selectedX = interpolateX(for: selectedTime)
        return timeX - selectedX
    }

    /// Interpolate within the anchor table to find the X position for any time.
    private func interpolateX(for time: Date) -> CGFloat {
        guard anchors.count >= 2 else { return 0 }

        // Before first anchor
        if time <= anchors.first!.time {
            let dist = anchors.first!.time.timeIntervalSince(time) / 60
            return anchors.first!.x - CGFloat(dist) * TimeSliderMetrics.pointsPerMinute
        }

        // After last anchor
        if time >= anchors.last!.time {
            let dist = time.timeIntervalSince(anchors.last!.time) / 60
            return anchors.last!.x + CGFloat(dist) * TimeSliderMetrics.pointsPerMinute
        }

        // Find surrounding anchors and interpolate
        for i in 0..<anchors.count - 1 {
            let a = anchors[i]
            let b = anchors[i + 1]
            if time >= a.time && time <= b.time {
                let totalSec = b.time.timeIntervalSince(a.time)
                guard totalSec > 0 else { return a.x }
                let fraction = CGFloat(time.timeIntervalSince(a.time) / totalSec)
                return a.x + fraction * (b.x - a.x)
            }
        }

        return 0
    }

    // MARK: - Drag

    func onDragStarted() {
        isUserDragging = true
        autoReturnTask?.cancel()
        hapticGenerator.prepare()
        lastHapticSlot = hapticSlot(for: selectedTime)
    }

    /// Called incrementally with dx delta (in points).
    /// Converts dx from compressed visual space back to real time movement.
    func onDragChanged(dx: CGFloat, invertDirection: Bool) {
        if !isUserDragging { onDragStarted() }
        // Always cancel pending auto-return (covers re-drag while timer is active)
        autoReturnTask?.cancel()
        let direction: CGFloat = invertDirection ? 1 : -1

        // Convert visual dx back to time by finding what time corresponds to the new X
        let currentX = interpolateX(for: selectedTime)
        let newX = currentX + direction * dx
        selectedTime = interpolateTime(for: newX)

        // Haptic feedback at interval crossings
        let currentSlot = hapticSlot(for: selectedTime)
        if currentSlot != lastHapticSlot {
            hapticGenerator.selectionChanged()
            hapticGenerator.prepare()
            lastHapticSlot = currentSlot
        }

        checkTimelineRebuildNeeded()
    }

    /// Reverse lookup: given an X position, find the corresponding time.
    private func interpolateTime(for x: CGFloat) -> Date {
        guard anchors.count >= 2 else { return selectedTime }

        // Before first anchor
        if x <= anchors.first!.x {
            let dist = anchors.first!.x - x
            let minutes = Double(dist / TimeSliderMetrics.pointsPerMinute)
            return anchors.first!.time.addingTimeInterval(-minutes * 60)
        }

        // After last anchor
        if x >= anchors.last!.x {
            let dist = x - anchors.last!.x
            let minutes = Double(dist / TimeSliderMetrics.pointsPerMinute)
            return anchors.last!.time.addingTimeInterval(minutes * 60)
        }

        for i in 0..<anchors.count - 1 {
            let a = anchors[i]
            let b = anchors[i + 1]
            if x >= a.x && x <= b.x {
                let totalX = b.x - a.x
                guard totalX > 0 else { return a.time }
                let fraction = Double((x - a.x) / totalX)
                let totalSec = b.time.timeIntervalSince(a.time)
                return a.time.addingTimeInterval(fraction * totalSec)
            }
        }

        return selectedTime
    }

    private func hapticSlot(for time: Date) -> Int {
        let interval = TimeSliderMetrics.dragHapticIntervalMinutes * 60
        return Int(floor(time.timeIntervalSinceReferenceDate / interval))
    }

    func onDragEnded() {
        startAutoReturn()
    }

    func returnToNow() {
        autoReturnTask?.cancel()
        withAnimation(.bouncy(duration: 0.6)) {
            isUserDragging = false
            selectedTime = Date()
        }
    }

    func startAutoReturn() {
        autoReturnTask?.cancel()
        autoReturnTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            withAnimation(.bouncy(duration: 0.6)) {
                isUserDragging = false
                selectedTime = Date()
            }
        }
    }

}
