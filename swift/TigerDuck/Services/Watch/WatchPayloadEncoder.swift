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
        languageTag: String?,
        visualPreset: VisualPreset,
        quietDays: Set<String> = []
    ) -> WatchSnapshot {
        // No courses when logged out: the previous user's may still be cached when this push
        // fires, and the watch's NowNextView checks `courses` before `loggedIn`, so it would
        // keep showing their schedule on a signed-out watch.
        let watchCourses = loggedIn
            ? courses.flatMap { flatten($0, customNames: customNames) }
            : []
        let syncedAtMs = Int64((syncedAt.timeIntervalSince1970 * 1000).rounded())
        return WatchSnapshot(
            courses: watchCourses,
            accentHex: accentHex,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag,
            visualPreset: visualPreset,
            clockOverrideJSON: encodedClockOverride(),
            quietDays: quietDays
        )
    }

    /// Serialises the current debug time override (if any) for transport
    /// to the watch. `#if DEBUG`-gated: Release builds never emit the
    /// field, so the watch receives `nil` and stays on real wall time.
    private static func encodedClockOverride() -> String? {
        #if DEBUG
        guard let override = AppClock.currentOverride() else { return nil }
        guard let data = try? JSONEncoder().encode(override),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
        #else
        return nil
        #endif
    }

    private static func flatten(_ course: SDCourse, customNames: [String: String]) -> [WatchCourse] {
        // Split non-contiguous periods on one weekday (3,4,6,7) into runs, or the watch and
        // complication show one block across the gap and call it "current" during the free
        // period. Mirrors `WidgetTimelineDerivation.contiguousRuns` in the iOS widget.
        let order = AppConstants.Periods.chronologicalOrder
        let skipped = Set(course.skippedDates)
        return course.schedule.flatMap { weekday, periodIds -> [WatchCourse] in
            let sorted = periodIds.sortedByPeriodOrder()
            return contiguousRuns(sorted, by: order).compactMap { run -> WatchCourse? in
                guard let first = run.first,
                      let last = run.last,
                      let startPeriod = TimetablePeriod.byId[first],
                      let endPeriod = TimetablePeriod.byId[last] else { return nil }
                let label = run.count > 1 ? "\(first)-\(last)" : first
                return WatchCourse(
                    id: "\(course.courseNo)-\(weekday)-\(first)",
                    courseNo: course.courseNo,
                    name: resolveDisplayName(course: course, customNames: customNames),
                    teacher: course.instructor,
                    classroom: course.classroom(weekday: weekday, periods: run),
                    colorHex: courseColorHex(course),
                    weekday: weekday,
                    startHHmm: startPeriod.startTime,
                    endHHmm: endPeriod.endTime,
                    periodLabel: label,
                    skippedDates: skipped.isEmpty ? nil : skipped
                )
            }
        }
        .sorted { ($0.weekday, $0.startHHmm) < ($1.weekday, $1.startHHmm) }
    }

    private static func contiguousRuns(_ periods: [String], by order: [String]) -> [[String]] {
        var runs: [[String]] = []
        var current: [String] = []
        var prevIndex = Int.min
        for period in periods {
            let idx = order.firstIndex(of: period) ?? Int.min
            if !current.isEmpty, idx == prevIndex + 1 {
                current.append(period)
            } else {
                if !current.isEmpty { runs.append(current) }
                current = [period]
            }
            prevIndex = idx
        }
        if !current.isEmpty { runs.append(current) }
        return runs
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
