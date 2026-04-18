import Foundation

/// Selects the single Live Activity snapshot that should be shown right now,
/// or nil if no scenario qualifies under current preferences.
///
/// Priority (spec section 8):
/// 1. inClass         — current course not skipped
/// 2. classPreparing  — next non-skipped course within `classPreparingLeadTime`
/// 3. assignmentUrgent — earliest uncompleted assignment due within `assignmentLiveActivityLeadTime`
///
/// Tie-breakers:
/// - assignmentUrgent: earliest due date
/// - classPreparing:   soonest start
/// - inClass:          earliest start (handled implicitly since we keep the
///                     first matching slot in the sorted timeline)
struct LiveActivityScenarioResolver {
    let timelineResolver: CourseTimelineResolver

    init(timelineResolver: CourseTimelineResolver = CourseTimelineResolver()) {
        self.timelineResolver = timelineResolver
    }

    func resolve(
        courses: [SDCourse],
        assignments: [SDAssignment],
        preferences: LiveActivityPreferencesStore,
        accentHex: Int,
        now: Date = Date()
    ) -> LiveActivitySnapshot? {
        guard preferences.isLiveActivityEnabled else { return nil }

        let timeline = timelineResolver.timeline(for: courses, around: now)

        if preferences.showInClassScenario,
           case .inClass(let slot) = timelineResolver.nonSkippedState(at: now, in: timeline) {
            return Self.inClassSnapshot(slot: slot, now: now, accentHex: accentHex)
        }

        if preferences.showClassPreparingScenario,
           let nextSlot = Self.nextNonSkippedSlot(in: timeline, after: now),
           nextSlot.start.timeIntervalSince(now) <= preferences.classPreparingLeadTime {
            return Self.classPreparingSnapshot(slot: nextSlot, accentHex: accentHex)
        }

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
                now: now,
                accentHex: accentHex
            )
        }

        return nil
    }

    // MARK: - Snapshot factories (static, pure — easy to unit test)

    static func inClassSnapshot(slot: CourseTimeSlot, now: Date, accentHex: Int) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        return LiveActivitySnapshot(
            scenario: .inClass,
            title: slot.course.courseName,
            subtitle: slot.course.timeRange(for: weekday) ?? "",
            locationText: slot.course.classroom(for: weekday),
            instructor: nonEmpty(slot.course.instructor),
            countdownTarget: slot.end,
            progress: progress(from: slot.start, to: slot.end, at: now),
            accentHex: accentHex,
            deepLink: nil,
            sourceId: slot.id
        )
    }

    static func classPreparingSnapshot(slot: CourseTimeSlot, accentHex: Int) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        return LiveActivitySnapshot(
            scenario: .classPreparing,
            title: slot.course.courseName,
            subtitle: slot.course.timeRange(for: weekday) ?? "",
            locationText: slot.course.classroom(for: weekday),
            instructor: nonEmpty(slot.course.instructor),
            countdownTarget: slot.start,
            progress: nil,
            accentHex: accentHex,
            deepLink: nil,
            sourceId: slot.id
        )
    }

    static func assignmentSnapshot(
        assignment: SDAssignment,
        courses: [SDCourse] = [],
        leadTime: TimeInterval,
        now: Date = Date(),
        accentHex: Int
    ) -> LiveActivitySnapshot {
        let instructor = courses
            .first { $0.courseNo == assignment.courseNo }
            .flatMap { nonEmpty($0.instructor) }
        return LiveActivitySnapshot(
            scenario: .assignmentUrgent,
            title: assignment.title,
            subtitle: assignment.courseName,
            locationText: nil,
            instructor: instructor,
            countdownTarget: assignment.dueDate,
            progress: assignmentProgress(dueDate: assignment.dueDate, leadTime: leadTime, now: now),
            accentHex: accentHex,
            deepLink: assignment.moodleDeepLink,
            sourceId: assignment.assignmentId
        )
    }

    /// 作業進度條：以 `leadTime` 為分母，距離截止越近進度越滿。
    /// start = dueDate - leadTime；elapsed = now - start；progress = elapsed / leadTime。
    static func assignmentProgress(dueDate: Date, leadTime: TimeInterval, now: Date) -> Double? {
        guard leadTime > 0 else { return nil }
        let start = dueDate.addingTimeInterval(-leadTime)
        let elapsed = now.timeIntervalSince(start)
        return max(0, min(1, elapsed / leadTime))
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

    static func progress(from start: Date, to end: Date, at now: Date) -> Double? {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return nil }
        let elapsed = now.timeIntervalSince(start)
        return max(0, min(1, elapsed / total))
    }
}
