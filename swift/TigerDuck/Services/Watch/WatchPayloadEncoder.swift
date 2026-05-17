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
            languageTag: languageTag,
            clockOverrideJSON: encodedClockOverride()
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
        // A course meeting at non-contiguous periods on the same weekday
        // (e.g. 3,4,6,7) must be emitted as separate runs — otherwise the
        // watch and complication would render it as one block spanning the
        // gap and report it as "current" during the unscheduled period.
        // Mirrors `WidgetTimelineDerivation.contiguousRuns` used by the iOS
        // widget.
        let order = AppConstants.Periods.chronologicalOrder
        let classroomMap = course.classroomMap
        let flatClassroom = SDCourse.dedup(course.classroom)
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
                    classroom: classroomForRun(
                        weekday: weekday, run: run,
                        map: classroomMap, fallback: flatClassroom
                    ),
                    colorHex: courseColorHex(course),
                    weekday: weekday,
                    startHHmm: startPeriod.startTime,
                    endHHmm: endPeriod.endTime,
                    periodLabel: label
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

    private static func classroomForRun(
        weekday: Int,
        run: [String],
        map: [String: String],
        fallback: String
    ) -> String {
        guard !map.isEmpty else { return fallback }
        var seen = Set<String>()
        var rooms: [String] = []
        for period in run {
            let key = "\(weekday)-\(period)"
            guard let raw = map[key] else { continue }
            for part in SDCourse.splitRoom(raw) where !seen.contains(part) {
                seen.insert(part)
                rooms.append(part)
            }
        }
        return rooms.isEmpty ? fallback : rooms.joined(separator: ", ")
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
