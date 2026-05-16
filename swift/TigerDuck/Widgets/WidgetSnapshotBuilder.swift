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
        let customColors: [String: Int]
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
                colorHex: resolveColor(courseNo: course.courseNo, customColors: input.customColors)
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

    /// 20-color palette mirroring `TigerDuckTheme.courseColors` as raw hex
    /// so this file stays SwiftUI-free and the builder remains trivially
    /// unit-testable. Keep in lock-step with `TigerDuckTheme.courseColors`
    /// (same order, same hex) — any drift here causes the widget to render
    /// a course in a different color than the app.
    static let coursePaletteHex: [UInt32] = [
        0xFF6B6B, 0x4ECDC4, 0x45B7D1, 0xF39C12, 0xDDA0DD,
        0x2ECC71, 0xE74C3C, 0x3498DB, 0xF7DC6F, 0x9B59B6,
        0x1ABC9C, 0xE67E22, 0x85C1E9, 0xD35400, 0x27AE60,
        0xC0392B, 0x8E44AD, 0x16A085, 0xF1C40F, 0x2980B9,
    ]

    /// Resolves the course color the same way the app does:
    /// 1. Honor an explicit `customColors[courseNo]` palette-index override
    ///    (out-of-range indices fall through to the hash default).
    /// 2. Otherwise hash `courseNo.utf8` with the identical polynomial the
    ///    app uses in `TigerDuckTheme.stableColor(for:)` so a course shows
    ///    the same color in the widget and on the timetable.
    private static func resolveColor(courseNo: String, customColors: [String: Int]) -> UInt32 {
        if let index = customColors[courseNo], coursePaletteHex.indices.contains(index) {
            return coursePaletteHex[index]
        }
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
