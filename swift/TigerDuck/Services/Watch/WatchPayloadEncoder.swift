import Foundation

/// Phone-side flattener: takes the user's `SDCourse[]` and per-feature
/// preferences and produces a `WatchSnapshot` ready for `WatchPayloadCodec`.
///
/// A course meeting twice a week becomes two `WatchCourse` rows — each
/// row represents one concrete weekday session.
enum WatchPayloadEncoder {

    static func encode(
        courses: [SDCourse],
        accentHex: String,
        syncedAt: Date,
        loggedIn: Bool,
        languageTag: String?
    ) -> WatchSnapshot {
        let watchCourses = courses.flatMap { flatten($0) }
        let syncedAtMs = Int64((syncedAt.timeIntervalSince1970 * 1000).rounded())
        return WatchSnapshot(
            courses: watchCourses,
            accentHex: accentHex,
            syncedAtMs: syncedAtMs,
            loggedIn: loggedIn,
            languageTag: languageTag
        )
    }

    private static func flatten(_ course: SDCourse) -> [WatchCourse] {
        course.schedule.compactMap { weekday, periodIds in
            guard let first = periodIds.first,
                  let last = periodIds.last,
                  let startPeriod = TimetablePeriod.byId[first],
                  let endPeriod = TimetablePeriod.byId[last] else { return nil }

            let classroom = classroomFor(course, weekday: weekday, firstPeriod: first)
                ?? course.classroom
            let label = periodIds.count > 1
                ? "\(first)-\(last)"
                : first

            return WatchCourse(
                id: "\(course.courseNo)-\(weekday)-\(first)",
                courseNo: course.courseNo,
                name: course.courseName,
                teacher: course.instructor,
                classroom: classroom,
                colorHex: courseColorHex(course),
                weekday: weekday,
                startHHmm: startPeriod.startTime,
                endHHmm: endPeriod.endTime,
                periodLabel: label
            )
        }
        .sorted { ($0.weekday, $0.startHHmm) < ($1.weekday, $1.startHHmm) }
    }

    /// Look up the classroom for a specific (weekday, firstPeriod) cell.
    /// Falls back to the course's default classroom if no override is set.
    private static func classroomFor(_ course: SDCourse, weekday: Int, firstPeriod: String) -> String? {
        let key = "\(weekday)-\(firstPeriod)"
        return course.classroomMap[key]
    }

    /// Phone keeps the user's chosen per-course color in a separate store
    /// (currently `AppConstants.CourseColors` / user preference). For v1 we
    /// fall back to the global accent — Task 17 wires the per-course
    /// override into the encoder.
    private static func courseColorHex(_ course: SDCourse) -> String {
        return WatchSnapshot.defaultAccentHex
    }
}
