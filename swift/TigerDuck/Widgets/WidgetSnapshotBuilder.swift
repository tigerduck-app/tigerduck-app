import Foundation

enum WidgetSnapshotBuilder {
    struct Input {
        let courses: [SDCourse]
        let customNames: [String: String]
        let colorMap: [String: UInt32]
        let isLoggedIn: Bool
        let accentColorHex: UInt32
        let now: Date
        var quietDayKeys: Set<String> = []
        var changes: CourseChanges = .empty
    }

    static func build(_ input: Input) -> WidgetSnapshot {
        let snapshotCourses = input.courses.map { course in
            SnapshotCourse(
                courseNo: course.courseNo,
                displayName: resolveDisplayName(course: course, customNames: input.customNames),
                classroom: course.classroom,
                schedule: course.schedule,
                colorHex: resolveColor(courseNo: course.courseNo, colorMap: input.colorMap),
                skippedDates: Set(course.skippedDates),
                classroomMap: course.classroomMap,
                changes: snapshotChanges(of: course, changes: input.changes)
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
            quietDayKeys: Array(input.quietDayKeys).sorted()
        )
    }

    /// Every changed meeting of the term, so a widget left alone for days still shows them.
    static func snapshotChanges(of course: SDCourse, changes: CourseChanges) -> [SnapshotCourseChange] {
        changes.days(courseNo: course.courseNo).flatMap { day in
            CourseTimeSlot.changedMeetings(of: course, on: day, changes: changes)
                .filter { $0.isCancelled || $0.hasChangedRoom || $0.hasChangedTime }
                .map { meeting in
                    SnapshotCourseChange(
                        day: WidgetTimelineDerivation.dateKey(for: day),
                        periods: meeting.periods,
                        cancelled: meeting.isCancelled,
                        room: meeting.hasChangedRoom ? meeting.room : nil,
                        start: meeting.originalStart == nil ? nil : meeting.start.timeString,
                        end: meeting.originalEnd == nil ? nil : meeting.end.timeString
                    )
                }
        }
    }

    private static func resolveDisplayName(
        course: SDCourse,
        customNames: [String: String]
    ) -> String {
        if let custom = customNames[course.courseNo], !custom.isEmpty { return custom }
        return course.courseName
    }

    static let coursePaletteHex: [UInt32] = [
        0xFF6B6B, 0x4ECDC4, 0x45B7D1, 0xF39C12, 0xDDA0DD,
        0x2ECC71, 0xE74C3C, 0x3498DB, 0xF7DC6F, 0x9B59B6,
        0x1ABC9C, 0xE67E22, 0x85C1E9, 0xD35400, 0x27AE60,
        0xC0392B, 0x8E44AD, 0x16A085, 0xF1C40F, 0x2980B9,
    ]

    private static func resolveColor(courseNo: String, colorMap: [String: UInt32]) -> UInt32 {
        if let hex = colorMap[courseNo] { return hex }
        let hash = courseNo.utf8.reduce(0) { ($0 &* 31) &+ Int($1) }
        return coursePaletteHex[abs(hash) % coursePaletteHex.count]
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
