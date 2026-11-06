import Foundation
import TigerDuckCore

enum WidgetSnapshotBuilder {
    struct Input {
        var courses: [SDCourse]
        var customNames: [String: String]
        let colorMap: [String: UInt32]
        let isLoggedIn: Bool
        let accentColorHex: UInt32
        let now: Date
        var quietDayKeys: Set<String> = []
        var changes: CourseChanges = .empty
        var term: QuietDayCalendar.Span? = nil
    }

    static func build(_ input: Input) -> WidgetSnapshot {
        let snapshotCourses = input.courses.map { course in
            SnapshotCourse(
                courseNo: course.courseNo,
                displayName: resolveDisplayName(course: course, customNames: input.customNames),
                classroom: course.classroom,
                schedule: course.schedule,
                colorHex: input.colorMap[course.courseNo]
                    ?? ColorState.unassignedHex(for: course.courseNo, palette: TigerDuckTheme.coursePaletteHexes),
                skippedDates: Set(course.skippedDates),
                classroomMap: course.classroomMap,
                changes: snapshotChanges(of: course, changes: input.changes),
                meetingChanges: snapshotMeetingChanges(of: course, changes: input.changes)
            )
        }

        return WidgetSnapshot(
            version: WidgetSnapshot.currentVersion,
            generatedAt: input.now,
            isLoggedIn: input.isLoggedIn,
            accentColorHex: input.accentColorHex,
            courses: snapshotCourses,
            periodTimes: buildPeriodTimes(),
            periodOrder: AppConstants.Periods.chronologicalOrder,
            activeWeekdays: computeActiveWeekdays(input.courses),
            activePeriodIds: computeActivePeriodIds(input.courses),
            quietDayKeys: Array(input.quietDayKeys).sorted(),
            term: input.term
        )
    }

    /// The classes of every changed meeting of the term, so a widget left alone for days still
    /// shows them.
    static func snapshotChanges(of course: SDCourse, changes: CourseChanges) -> [SnapshotCourseChange] {
        changes.days(courseNo: course.courseNo).flatMap { day in
            CourseTimeSlot.changedClasses(of: course, on: day, changes: changes).map(snapshotChange)
        }
    }

    static func snapshotMeetingChanges(of course: SDCourse, changes: CourseChanges) -> [SnapshotCourseChange] {
        changes.days(courseNo: course.courseNo).flatMap { day in
            CourseTimeSlot.changedMeetings(of: course, on: day, changes: changes)
                .filter { $0.isCancelled || $0.hasChangedRoom || $0.hasChangedTime }
                .map(snapshotChange)
        }
    }

    private static func snapshotChange(_ slot: CourseTimeSlot) -> SnapshotCourseChange {
        SnapshotCourseChange(
            day: WidgetTimelineDerivation.dateKey(for: slot.date),
            periods: slot.periods,
            cancelled: slot.isCancelled,
            room: slot.hasChangedRoom ? slot.room : nil,
            start: slot.originalStart == nil ? nil : slot.start.timeString,
            end: slot.originalEnd == nil ? nil : slot.end.timeString
        )
    }

    private static func resolveDisplayName(
        course: SDCourse,
        customNames: [String: String]
    ) -> String {
        if let custom = customNames[course.courseNo], !custom.isEmpty { return custom }
        return course.courseName
    }

    private static func buildPeriodTimes() -> [String: PeriodTime] {
        var dict: [String: PeriodTime] = [:]
        for periodId in AppConstants.Periods.chronologicalOrder {
            if let pair = AppConstants.PeriodTimes.mapping[periodId] {
                dict[periodId] = PeriodTime(start: pair.start, end: pair.end)
            }
        }
        return dict
    }

    private static func computeActiveWeekdays(_ courses: [SDCourse]) -> [Int] {
        var weekdays = Set([1, 2, 3, 4, 5])
        for course in courses {
            for day in course.schedule.keys where day == 6 || day == 7 {
                weekdays.insert(day)
            }
        }
        return weekdays.sorted()
    }

    private static func computeActivePeriodIds(_ courses: [SDCourse]) -> [String] {
        var ids = Set(AppConstants.Periods.defaultVisible)
        for course in courses {
            for periods in course.schedule.values {
                ids.formUnion(periods)
            }
        }
        return AppConstants.Periods.chronologicalOrder.filter { ids.contains($0) }
    }
}
