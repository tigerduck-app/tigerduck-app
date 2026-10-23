import Foundation

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
        calendar: AcademicCalendar = .empty,
        optedInHolidayIDs: Set<Int> = []
    ) -> LiveActivitySnapshot? {
        guard effectiveLiveActivityEnabled(
            isLiveActivityEnabled: preferences.isLiveActivityEnabled,
            cloudSyncEnabled: cloudSyncEnabled
        ) else { return nil }

        let classesQuiet = !calendar.isClassDay(now, optedIn: optedInHolidayIDs)

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

    static func inClassSnapshot(slot: CourseTimeSlot, now: Date, accentHex: Int) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        return LiveActivitySnapshot(
            scenario: .inClass,
            title: slot.course.displayName,
            subtitle: "\(slot.start.timeString) - \(slot.end.timeString)",
            locationText: slot.course.classroom(weekday: weekday, periods: slot.periods),
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
            subtitle: "\(slot.start.timeString) - \(slot.end.timeString)",
            locationText: slot.course.classroom(weekday: weekday, periods: slot.periods),
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
            deepLink: WidgetURLRouter.assignmentURL(id: assignment.assignmentId),
            sourceId: assignment.assignmentId
        )
    }

    private static func nonEmpty(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

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
            .filter { isOutstanding($0) && $0.dueDate > now }
            .filter { $0.dueDate.timeIntervalSince(now) <= leadTime }
            .min { $0.dueDate < $1.dueDate }
    }

    static func isOutstanding(_ assignment: SDAssignment) -> Bool {
        !assignment.isCompleted && !assignment.isArchived && !assignment.isLocallyCompleted
    }

    static func isOutstanding(assignmentId id: String, in assignments: [SDAssignment]) -> Bool? {
        assignments.first { $0.assignmentId == id }.map { isOutstanding($0) }
    }

}
