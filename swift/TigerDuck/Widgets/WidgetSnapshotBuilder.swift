import Foundation

/// Pure-function builder that converts app-side state (SwiftData courses +
/// preferences) into a `WidgetSnapshot` ready to be encoded and written to
/// the shared App Group. Lives in the main app target — the widget extension
/// only ever reads the encoded payload, never runs this code.
///
/// Kept deliberately free of `@MainActor`, persistence, and SwiftUI imports
/// so it stays trivially unit-testable without spinning up a SwiftData
/// container.
enum WidgetSnapshotBuilder {
    struct Input {
        let courses: [SDCourse]
        let customNames: [String: String]
        let isLoggedIn: Bool
        let accentColorHex: UInt32
        let now: Date
    }

    static func build(_ input: Input) -> WidgetSnapshot {
        let snapshotCourses = input.courses.map { course in
            SnapshotCourse(
                courseNo: course.courseNo,
                displayName: resolveDisplayName(course: course, customNames: input.customNames),
                classroom: course.classroom,
                schedule: course.schedule,
                colorHex: hashPaletteColor(course.courseNo)
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
            activePeriodIds: computeActivePeriodIds(input.courses)
        )
    }

    private static func resolveDisplayName(
        course: SDCourse,
        customNames: [String: String]
    ) -> String {
        if let custom = customNames[course.courseNo], !custom.isEmpty { return custom }
        return course.courseName
    }

    /// Deterministic per-course color. Mirrors the `Theme/Color+Extensions.swift`
    /// selection so the widget matches the in-app card color enough that users
    /// recognize their classes; exact parity with `TigerDuckTheme.courseColor`
    /// is deferred — that path requires importing SwiftUI/Theme into the
    /// widget extension and is tracked as a follow-up.
    private static func hashPaletteColor(_ courseNo: String) -> UInt32 {
        let hash = courseNo.reduce(0) { acc, c in (acc &* 31 &+ Int(c.asciiValue ?? 0)) & 0x7FFFFFFF }
        let palette: [UInt32] = [
            0xFF6B6B, 0x4ECDC4, 0xFFE66D, 0x95E1D3, 0xF38181,
            0xAA96DA, 0xFCBAD3, 0xA8D8EA, 0xFFAAA5, 0xFFD3B6,
        ]
        return palette[hash % palette.count]
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

    /// Mon–Fri are always shown; Sat (6) and Sun (7) appear only when at
    /// least one course schedules a slot on that day. Matches the in-app
    /// timetable's "weekend column auto-show" behavior so the widget grid
    /// has the same width as the main view.
    private static func computeActiveWeekdays(_ courses: [SDCourse]) -> [Int] {
        var weekdays = Set([1, 2, 3, 4, 5])
        for course in courses {
            for day in course.schedule.keys where day == 6 || day == 7 {
                weekdays.insert(day)
            }
        }
        return weekdays.sorted()
    }

    /// Default-visible periods are always emitted; extended periods (5, 10,
    /// A–D) join only when a course actually uses them. The result is
    /// re-sorted by `chronologicalOrder` so encoded JSON is stable across
    /// builds (Set iteration order is not).
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
