import Foundation

/// Picks the one Live Activity snapshot to show now, or nil when none qualifies or
/// Live Activity is unavailable (`effectiveLiveActivityEnabled`). Assignments come
/// first, a product decision, so a due-soon warning still shows during class; users
/// who turn off `showAssignmentScenario` get class-first behavior. In priority order:
/// 1. assignmentUrgent: the uncompleted assignment due soonest within `assignmentLiveActivityLeadTime`.
/// 2. inClass: the current non-skipped course. Overlapping slots come back in timeline
///    order and one activity shows one class, so the earliest start wins.
/// 3. classPreparing: the soonest non-skipped course within `classPreparingLeadTime`.
struct LiveActivityScenarioResolver {
    let timelineResolver: CourseTimelineResolver

    init(timelineResolver: CourseTimelineResolver = CourseTimelineResolver()) {
        self.timelineResolver = timelineResolver
    }

    #if os(iOS)
    func resolve(
        courses: [SDCourse],
        assignments: [SDAssignment],
        preferences: LiveActivityPreferencesStore,
        cloudSyncEnabled: Bool,
        accentHex: Int,
        now: Date = AppClock.now(),
        /// Days classes do not meet. Passed in rather than read from the
        /// store so this stays a pure function of its inputs and can be
        /// tested without a `@MainActor` singleton.
        calendar: AcademicCalendar = .empty,
        optedInHolidayIDs: Set<Int> = []
    ) -> LiveActivitySnapshot? {
        // Cloud sync off makes Live Activity unavailable, like the user's own
        // switch off. `effectiveLiveActivityEnabled` is the one place that
        // combined answer is computed.
        guard effectiveLiveActivityEnabled(
            isLiveActivityEnabled: preferences.isLiveActivityEnabled,
            cloudSyncEnabled: cloudSyncEnabled
        ) else { return nil }

        // The class scenarios go quiet on a school holiday. The assignment
        // scenario deliberately does not: a deadline on a day off is still
        // a deadline, and holidays are about classes not meeting.
        let classesQuiet = calendar.suppressesClasses(on: now, optedIn: optedInHolidayIDs)

        let timeline = timelineResolver.timeline(for: courses, around: now)

        if preferences.showAssignmentScenario,
           let urgent = Self.earliestUrgentAssignment(
               assignments: assignments,
               leadTime: preferences.assignmentLiveActivityLeadTime,
               now: now
           ) {
            return Self.assignmentSnapshot(
                assignment: urgent,
                courses: courses,
                leadTime: preferences.assignmentLiveActivityLeadTime,
                accentHex: accentHex
            )
        }

        if !classesQuiet,
           preferences.showInClassScenario,
           case .inClass(let slots) = timelineResolver.nonSkippedState(at: now, in: timeline),
           let slot = slots.first {
            return Self.inClassSnapshot(slot: slot, now: now, accentHex: accentHex)
        }

        if !classesQuiet,
           preferences.showClassPreparingScenario,
           let nextSlot = Self.nextNonSkippedSlot(in: timeline, after: now),
           nextSlot.start.timeIntervalSince(now) <= preferences.classPreparingLeadTime {
            return Self.classPreparingSnapshot(slot: nextSlot, accentHex: accentHex)
        }

        return nil
    }
    #endif

    // MARK: - Snapshot factories (static, pure — easy to unit test)

    static func inClassSnapshot(slot: CourseTimeSlot, now: Date, accentHex: Int) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        return LiveActivitySnapshot(
            scenario: .inClass,
            title: slot.course.displayName,
            // The active block's own range, not the day's first-to-last span. For a
            // course split within a day, such as P3-P4 plus P7-P8, countdown and progress
            // cover this slot, and the subtitle must match rather than span the gap.
            subtitle: "\(slot.start.timeString) - \(slot.end.timeString)",
            locationText: slot.course.classroom(for: weekday),
            instructor: nonEmpty(slot.course.instructor),
            countdownTarget: slot.end,
            progressStart: slot.start < slot.end ? slot.start : nil,
            accentHex: accentHex,
            deepLink: nil,
            sourceId: slot.id
        )
    }

    static func classPreparingSnapshot(slot: CourseTimeSlot, accentHex: Int) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        return LiveActivitySnapshot(
            scenario: .classPreparing,
            title: slot.course.displayName,
            // Same reason as inClassSnapshot: the upcoming slot is one
            // specific block, so subtitle must reflect that block — not
            // an earlier block plus the gap leading to this one.
            subtitle: "\(slot.start.timeString) - \(slot.end.timeString)",
            locationText: slot.course.classroom(for: weekday),
            instructor: nonEmpty(slot.course.instructor),
            countdownTarget: slot.start,
            progressStart: nil,
            accentHex: accentHex,
            deepLink: nil,
            sourceId: slot.id
        )
    }

    static func assignmentSnapshot(
        assignment: SDAssignment,
        courses: [SDCourse] = [],
        leadTime: TimeInterval,
        accentHex: Int
    ) -> LiveActivitySnapshot {
        let matchingCourse = courses.first { $0.courseNo == assignment.courseNo }
        let instructor = matchingCourse.flatMap { nonEmpty($0.instructor) }
        let progressStart: Date? = leadTime > 0
            ? assignment.dueDate.addingTimeInterval(-leadTime)
            : nil
        return LiveActivitySnapshot(
            scenario: .assignmentUrgent,
            title: assignment.displayTitle,
            subtitle: assignment.displayCourseName(matching: matchingCourse),
            locationText: nil,
            instructor: instructor,
            countdownTarget: assignment.dueDate,
            progressStart: progressStart,
            accentHex: accentHex,
            deepLink: assignment.moodleDeepLink,
            sourceId: assignment.assignmentId
        )
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Selection helpers

    static func nextNonSkippedSlot(in timeline: [CourseTimeSlot], after time: Date) -> CourseTimeSlot? {
        timeline
            .filter { !$0.course.isSkipped(on: $0.date) && $0.start > time }
            .min { $0.start < $1.start }
    }

    static func earliestUrgentAssignment(
        assignments: [SDAssignment],
        leadTime: TimeInterval,
        now: Date
    ) -> SDAssignment? {
        assignments
            .filter { !$0.isCompleted && $0.dueDate > now }
            .filter { $0.dueDate.timeIntervalSince(now) <= leadTime }
            .min { $0.dueDate < $1.dueDate }
    }

}
