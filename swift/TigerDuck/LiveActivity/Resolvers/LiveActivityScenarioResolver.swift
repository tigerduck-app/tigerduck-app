import Foundation

/// Selects the single Live Activity snapshot that should be shown right now,
/// or nil if no scenario qualifies under current preferences.
///
/// Priority:
/// 1. assignmentUrgent — earliest uncompleted assignment due within `assignmentLiveActivityLeadTime`
/// 2. inClass         — current course not skipped
/// 3. classPreparing  — next non-skipped course within `classPreparingLeadTime`
///
/// 作業放最高級是產品決策：未完成作業進入 lead time 時要優先蓋掉課堂，
/// 讓學生在上課時仍然看得到「快遲交」警示。使用者可在設定裡關閉
/// `showAssignmentScenario` 退回到原本「上課優先」的行為。
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

        if preferences.showInClassScenario,
           case .inClass(let slot) = timelineResolver.nonSkippedState(at: now, in: timeline) {
            return Self.inClassSnapshot(slot: slot, now: now, accentHex: accentHex)
        }

        if preferences.showClassPreparingScenario,
           let nextSlot = Self.nextNonSkippedSlot(in: timeline, after: now),
           nextSlot.start.timeIntervalSince(now) <= preferences.classPreparingLeadTime {
            return Self.classPreparingSnapshot(slot: nextSlot, accentHex: accentHex)
        }

        return nil
    }

    // MARK: - Snapshot factories (static, pure — easy to unit test)

    static func inClassSnapshot(slot: CourseTimeSlot, now: Date, accentHex: Int) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        return LiveActivitySnapshot(
            scenario: .inClass,
            title: slot.course.displayName,
            subtitle: slot.course.timeRange(for: weekday) ?? "",
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
            subtitle: slot.course.timeRange(for: weekday) ?? "",
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
