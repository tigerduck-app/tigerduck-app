import SwiftUI
import UIKit
import TigerDuckCore

@Observable
final class TimeSliderViewModel {
    private var prefersReducedMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    var timeSlots: [CourseTimeSlot] = [] {
        didSet { layout = TimeSliderLayout(slots: timeSlots) }
    }

    private(set) var layout = TimeSliderLayout()

    var slotLanes: [String: TimeSliderLane] { layout.lanes }

    var selectedTime: Date = AppClock.now()
    var isUserDragging: Bool = false

    private var allCourses: [CourseStore.Course] = []
    private var timelineCenterDate: Date = AppClock.now()
    private let haptics = TimeSliderHaptics()
    private let isQuietDay: (Date) -> Bool
    // `nonisolated(unsafe)` so `deinit` can remove them; `@ObservationIgnored`
    // keeps the macro from swapping the storage out from under the modifier.
    @ObservationIgnored
    private nonisolated(unsafe) var quietDayObservers: [Any] = []
    @ObservationIgnored private var storeObservation: StoreObservation?

    var hasCourses: Bool { !timeSlots.isEmpty }

    init(isQuietDay: @escaping (Date) -> Bool = { _ in false }) {
        self.isQuietDay = isQuietDay
        haptics.prepare()
        storeObservation = StoreObservation(read: { _ = AppDataRevision.current }) { [weak self] in
            self?.reloadQuietDays()
        }
        quietDayObservers = [
            AppConstants.holidayNotifyDidChange,
            AppConstants.courseSkipStateDidChange,
        ].map { name in
            NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadQuietDays() }
            }
        }
    }

    deinit {
        for observer in quietDayObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func configure(courses: [CourseStore.Course]) {
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
        ).filter { !isQuietDay($0.date) && !$0.isSkipped }
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
        ClassTimeline.state(at: time, in: timeSlots)
    }

    var currentCourseState: CourseState {
        courseState(at: selectedTime)
    }

    func xOffset(for time: Date) -> CGFloat {
        // Every tick calls this; one read keeps Observation's per-access cost out of the loop.
        let layout = layout
        return layout.x(for: time) - layout.x(for: selectedTime)
    }

    func onDragStarted() {
        isUserDragging = true
        haptics.start(at: selectedTime)
    }

    func onDragChanged(dx: CGFloat, invertDirection: Bool) {
        if !isUserDragging { onDragStarted() }
        let direction: CGFloat = invertDirection ? 1 : -1

        let layout = layout
        let newX = layout.x(for: selectedTime) + direction * dx
        selectedTime = layout.time(for: newX, fallback: selectedTime)
        haptics.move(to: selectedTime)

        checkTimelineRebuildNeeded()
    }

    func returnToNow() {
        withAnimation(prefersReducedMotion ? nil : .bouncy(duration: 0.6)) {
            isUserDragging = false
            selectedTime = AppClock.now()
        }
    }

}
