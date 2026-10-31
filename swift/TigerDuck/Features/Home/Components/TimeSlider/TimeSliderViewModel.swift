import SwiftUI
import UIKit
import TigerDuckCore

@Observable
final class TimeSliderViewModel {
    private var prefersReducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var timeSlots: [CourseTimeSlot] = [] {
        didSet { slotLanes = Self.lanes(for: timeSlots) }
    }

    private(set) var slotLanes: [String: TimeSliderLane] = [:]

    var selectedTime: Date = AppClock.now()
    var isUserDragging: Bool = false

    private var allCourses: [SDCourse] = []
    private var timelineCenterDate: Date = AppClock.now()
    private var lastHapticSlot: Int = 0
    private let hapticGenerator = UISelectionFeedbackGenerator()
    private let isQuietDay: (Date) -> Bool
    // `nonisolated(unsafe)` so `deinit` can remove them; `@ObservationIgnored`
    // keeps the macro from swapping the storage out from under the modifier.
    // Same pattern as `ClassTableViewModel.dataObserver`.
    @ObservationIgnored
    private nonisolated(unsafe) var quietDayObservers: [Any] = []

    var hasCourses: Bool { !timeSlots.isEmpty }

    private var anchors: [(time: Date, x: CGFloat)] = []

    init(isQuietDay: @escaping (Date) -> Bool = { _ in false }) {
        self.isQuietDay = isQuietDay
        hapticGenerator.prepare()
        quietDayObservers = [
            AppConstants.holidayNotifyDidChange,
            AppConstants.dataDidUpdate,
            AppConstants.courseSkipStateDidChange,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadQuietDays() }
            }
        }
    }

    convenience init(calendarStore: AcademicCalendarStore) {
        self.init(isQuietDay: { !calendarStore.isClassDay($0) })
    }

    deinit {
        for observer in quietDayObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(courses: [SDCourse]) {
        allCourses = courses
        rebuildTimeline(around: AppClock.now())
        if !isUserDragging {
            selectedTime = AppClock.now()
        }
    }

    func reloadQuietDays() {
        rebuildTimeline(around: timelineCenterDate)
    }

    private func rebuildTimeline(around center: Date) {
        timelineCenterDate = center
        timeSlots = CourseTimeSlot.buildMultiDaySlots(
            from: allCourses,
            centerDate: center,
            dayRadius: TimeSliderMetrics.timelineDayRadius
        ).filter { !isQuietDay($0.date) && !$0.course.isSkipped(on: $0.date) }
        rebuildAnchors()
    }

    private func rebuildAnchors() {
        let intervals = busyIntervals
        guard !intervals.isEmpty else { anchors = []; return }

        let ppm = TimeSliderMetrics.pointsPerMinute
        let refMin = TimeSliderMetrics.logarithmicReferenceMinutes
        let minGap = TimeSliderMetrics.minimumGapPoints
        let maxGap = TimeSliderMetrics.maximumGapPoints
        let dayGap = TimeSliderMetrics.dayBoundaryGapPoints

        var result: [(time: Date, x: CGFloat)] = []
        var x: CGFloat = 0

        let paddingBefore = compressedGapWidth(
            minutes: 60, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
        )
        result.append((time: intervals[0].start.addingTimeInterval(-3600), x: x))
        x += paddingBefore

        for (i, slot) in intervals.enumerated() {
            result.append((time: slot.start, x: x))

            let durationMin = slot.end.timeIntervalSince(slot.start) / 60
            x += CGFloat(durationMin) * ppm

            result.append((time: slot.end, x: x))

            if i + 1 < intervals.count {
                let next = intervals[i + 1]
                let gapMin = next.start.timeIntervalSince(slot.end) / 60

                let calendar = TaipeiTime.calendar
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

        let paddingAfter = compressedGapWidth(
            minutes: 60, refMin: refMin, ppm: ppm, minGap: minGap, maxGap: maxGap
        )
        x += paddingAfter
        if let last = intervals.last {
            result.append((time: last.end.addingTimeInterval(3600), x: x))
        }

        anchors = result
    }

    private var busyIntervals: [(start: Date, end: Date, date: Date)] {
        var result: [(start: Date, end: Date, date: Date)] = []
        for slot in timeSlots {
            if let last = result.last, slot.start < last.end {
                result[result.count - 1].end = max(last.end, slot.end)
            } else {
                result.append((start: slot.start, end: slot.end, date: slot.date))
            }
        }
        return result
    }

    static func lanes(for slots: [CourseTimeSlot]) -> [String: TimeSliderLane] {
        var lanes: [String: TimeSliderLane] = [:]
        var group: [CourseTimeSlot] = []
        var groupEnd = Date.distantPast
        func assignGroup() {
            guard group.count > 1 else { return }
            let assigned = OverlapLanes.assign(group.map { (start: $0.start, end: $0.end) })
            for (slot, lane) in zip(group, assigned.lanes) {
                lanes[slot.id] = TimeSliderLane(lane: lane, count: assigned.count)
            }
        }
        let byStart = slots.enumerated().sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
        for slot in byStart.map(\.element) {
            if slot.start < groupEnd {
                group.append(slot)
                groupEnd = max(groupEnd, slot.end)
            } else {
                assignGroup()
                group = [slot]
                groupEnd = slot.end
            }
        }
        assignGroup()
        return lanes
    }

    private func compressedGapWidth(
        minutes: Double, refMin: Double, ppm: CGFloat, minGap: CGFloat, maxGap: CGFloat
    ) -> CGFloat {
        guard minutes > 0 else { return minGap }
        let linear = CGFloat(minutes) * ppm
        let compressed = CGFloat(log(1 + minutes / refMin)) * ppm * CGFloat(refMin)
        let width = min(linear, compressed)
        return min(max(width, minGap), maxGap)
    }

    func tick(_ now: Date) {
        if !isUserDragging {
            selectedTime = now
        }
        checkTimelineRebuildNeeded()
    }

    private func checkTimelineRebuildNeeded() {
        let calendar = TaipeiTime.calendar
        let daysSinceCenter = abs(calendar.dateComponents(
            [.day], from: timelineCenterDate, to: selectedTime
        ).day ?? 0)
        if daysSinceCenter >= TimeSliderMetrics.timelineDayRadius - TimeSliderMetrics.timelineRebuildTriggerDays {
            rebuildTimeline(around: selectedTime)
        }
    }

    func courseState(at time: Date) -> CourseState {
        ClassTimeline.state(at: time, in: timeSlots, includingEnd: true)
    }

    var currentCourseState: CourseState {
        courseState(at: selectedTime)
    }

    func xOffset(for time: Date) -> CGFloat {
        let timeX = interpolateX(for: time)
        let selectedX = interpolateX(for: selectedTime)
        return timeX - selectedX
    }

    private func interpolateX(for time: Date) -> CGFloat {
        // Every tick calls this; one read keeps Observation's per-access cost out of the loop.
        let anchors = anchors
        guard anchors.count >= 2 else { return 0 }

        if time <= anchors.first!.time {
            let dist = anchors.first!.time.timeIntervalSince(time) / 60
            return anchors.first!.x - CGFloat(dist) * TimeSliderMetrics.pointsPerMinute
        }

        if time >= anchors.last!.time {
            let dist = time.timeIntervalSince(anchors.last!.time) / 60
            return anchors.last!.x + CGFloat(dist) * TimeSliderMetrics.pointsPerMinute
        }

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

    func onDragStarted() {
        isUserDragging = true
        hapticGenerator.prepare()
        lastHapticSlot = hapticSlot(for: selectedTime)
    }

    func onDragChanged(dx: CGFloat, invertDirection: Bool) {
        if !isUserDragging { onDragStarted() }
        let direction: CGFloat = invertDirection ? 1 : -1

        let currentX = interpolateX(for: selectedTime)
        let newX = currentX + direction * dx
        selectedTime = interpolateTime(for: newX)

        let currentSlot = hapticSlot(for: selectedTime)
        if currentSlot != lastHapticSlot {
            hapticGenerator.selectionChanged()
            hapticGenerator.prepare()
            lastHapticSlot = currentSlot
        }

        checkTimelineRebuildNeeded()
    }

    private func interpolateTime(for x: CGFloat) -> Date {
        let anchors = anchors
        guard anchors.count >= 2 else { return selectedTime }

        if x <= anchors.first!.x {
            let dist = anchors.first!.x - x
            let minutes = Double(dist / TimeSliderMetrics.pointsPerMinute)
            return anchors.first!.time.addingTimeInterval(-minutes * 60)
        }

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

    func returnToNow() {
        withAnimation(prefersReducedMotion ? nil : .bouncy(duration: 0.6)) {
            isUserDragging = false
            selectedTime = AppClock.now()
        }
    }

}

struct TimeSliderLane: Equatable {
    let lane: Int
    let count: Int
}
