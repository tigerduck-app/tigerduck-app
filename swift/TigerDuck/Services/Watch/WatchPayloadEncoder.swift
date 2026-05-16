import Foundation

/// Phone-side flattener: takes the user's `SDCourse[]` and per-feature
/// preferences and produces a `WatchSnapshot` ready for `WatchPayloadCodec`.
///
/// A course meeting twice a week becomes two `WatchCourse` rows — each
/// row represents one concrete weekday session.
enum WatchPayloadEncoder {

    static func encode(
        courses: [SDCourse],
        customNames: [String: String],
        accentHex: String,
        syncedAt: Date,
        loggedIn: Bool,
        languageTag: String?
    ) -> WatchSnapshot {
        // Drop cached courses on logout: SwiftData rows for the previous user
        // may still be present when this push fires, and the watch UI prefers
        // a non-empty `courses` over the `loggedIn` flag (NowNextView checks
        // courses first), so emitting them would leave the previous user's
        // schedule visible on a signed-out watch.
        let watchCourses = loggedIn
            ? courses.flatMap { flatten($0, customNames: customNames) }
            : []
        let syncedAtMs = Int64((syncedAt.timeIntervalSince1970 * 1000).rounded())
        return WatchSnapshot(
            courses: watchCourses,
            accentHex: accentHex,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag
        )
    }

    private static func flatten(_ course: SDCourse, customNames: [String: String]) -> [WatchCourse] {
        course.schedule.compactMap { weekday, periodIds in
            let sorted = periodIds.sortedByPeriodOrder()
            guard let first = sorted.first,
                  let last = sorted.last,
                  let startPeriod = TimetablePeriod.byId[first],
                  let endPeriod = TimetablePeriod.byId[last] else { return nil }

            let label = sorted.count > 1
                ? "\(first)-\(last)"
                : first

            return WatchCourse(
                id: "\(course.courseNo)-\(weekday)-\(first)",
                courseNo: course.courseNo,
                name: resolveDisplayName(course: course, customNames: customNames),
                teacher: course.instructor,
                classroom: course.classroom(for: weekday),
                colorHex: courseColorHex(course),
                weekday: weekday,
                startHHmm: startPeriod.startTime,
                endHHmm: endPeriod.endTime,
                periodLabel: label
            )
        }
        .sorted { ($0.weekday, $0.startHHmm) < ($1.weekday, $1.startHHmm) }
    }

    /// Mirror of `WidgetSnapshotBuilder.resolveDisplayName` — prefer the
    /// persisted alias overlay (canonical store) over the SDCourse
    /// `@Transient customName` (which may not be hydrated on every
    /// instance returned by SwiftData `@Query`), then fall back to the
    /// canonical API name.
    private static func resolveDisplayName(
        course: SDCourse,
        customNames: [String: String]
    ) -> String {
        if let alias = customNames[course.courseNo], !alias.isEmpty { return alias }
        if let alias = course.customName, !alias.isEmpty { return alias }
        return course.courseName
    }

    /// Phone keeps the user's per-course color override in
    /// `TigerDuckTheme`'s palette + custom-overrides cache. We surface the
    /// hex form so the watch can render the same swatch the user picked.
    private static func courseColorHex(_ course: SDCourse) -> String {
        TigerDuckTheme.courseColorHex(for: course.courseNo)
    }
}
