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
    private static let privacyTitle = "（隱藏中）"

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
            return Self.inClassSnapshot(
                slot: slot,
                now: now,
                accentHex: accentHex,
                privacyMode: preferences.privacyMode
            )
        }

        if preferences.showClassPreparingScenario,
           let nextSlot = Self.nextNonSkippedSlot(in: timeline, after: now),
           nextSlot.start.timeIntervalSince(now) <= preferences.classPreparingLeadTime {
            return Self.classPreparingSnapshot(
                slot: nextSlot,
                accentHex: accentHex,
                privacyMode: preferences.privacyMode
            )
        }

        if preferences.showAssignmentScenario,
           let urgent = Self.earliestUrgentAssignment(
               assignments: assignments,
               leadTime: preferences.assignmentLiveActivityLeadTime,
               now: now
           ) {
            return Self.assignmentSnapshot(
                assignment: urgent,
                accentHex: accentHex,
                privacyMode: preferences.privacyMode
            )
        }

        return nil
    }

    // MARK: - Snapshot factories (static, pure — easy to unit test)

    static func inClassSnapshot(
        slot: CourseTimeSlot,
        now: Date,
        accentHex: Int,
        privacyMode: Bool
    ) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        let title = privacyMode ? privacyTitle : slot.course.courseName
        let subtitle = slot.course.timeRange(for: weekday) ?? ""
        return LiveActivitySnapshot(
            scenario: .inClass,
            title: title,
            subtitle: subtitle,
            locationText: privacyMode ? nil : slot.course.classroom(for: weekday),
            countdownTarget: slot.end,
            progress: progress(from: slot.start, to: slot.end, at: now),
            accentHex: accentHex,
            deepLink: URL(string: "tigerduck://class/\(slot.course.courseNo)"),
            privacyMode: privacyMode,
            sourceId: slot.id
        )
    }

    static func classPreparingSnapshot(
        slot: CourseTimeSlot,
        accentHex: Int,
        privacyMode: Bool
    ) -> LiveActivitySnapshot {
        let weekday = slot.date.scheduleWeekday
        let title = privacyMode ? privacyTitle : "即將上課：\(slot.course.courseName)"
        let subtitle = slot.course.timeRange(for: weekday) ?? ""
        return LiveActivitySnapshot(
            scenario: .classPreparing,
            title: title,
            subtitle: subtitle,
            locationText: privacyMode ? nil : slot.course.classroom(for: weekday),
            countdownTarget: slot.start,
            progress: nil,
            accentHex: accentHex,
            deepLink: URL(string: "tigerduck://class/\(slot.course.courseNo)"),
            privacyMode: privacyMode,
            sourceId: slot.id
        )
    }

    static func assignmentSnapshot(
        assignment: SDAssignment,
        accentHex: Int,
        privacyMode: Bool
    ) -> LiveActivitySnapshot {
        let title = privacyMode ? privacyTitle : assignment.title
        let subtitle = privacyMode ? "作業即將到期" : assignment.courseName
        return LiveActivitySnapshot(
            scenario: .assignmentUrgent,
            title: title,
            subtitle: subtitle,
            locationText: nil,
            countdownTarget: assignment.dueDate,
            progress: nil,
            accentHex: accentHex,
            deepLink: assignment.moodleDeepLink,
            privacyMode: privacyMode,
            sourceId: assignment.assignmentId
        )
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
