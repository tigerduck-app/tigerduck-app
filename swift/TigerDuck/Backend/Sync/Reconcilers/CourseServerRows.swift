import Foundation
import TigerDuckCore

/// A term's course rows on the server read against this device: the rows kept, the courses a
/// roster dropped, and the courses built from a row.
enum CourseServerRows {
    /// The term's courses merged from the server that were dropped. One added by hand here has no
    /// Moodle ID; one added on another device keeps its `user_added` row in `keptRows`.
    static func droppedMerges(_ userAdded: [SDCourse], semester: String, dropped: Set<String>) -> Set<String> {
        Set(userAdded.filter {
            $0.moodleIdNumber != nil && dropped.contains($0.courseNo) && CourseStore.userAddedCourse($0, belongsTo: semester)
        }.map(\.courseNo))
    }

    /// The term's server rows, less those of courses course selection here dropped or a roster
    /// dropped on the server. A course the user added by hand keeps its row, so a drop never takes
    /// it out of the hand-added courses: one added here has no Moodle ID, which a row merged from the
    /// server always has, and one added on another device is a `user_added` row.
    static func keptRows(
        _ rows: [[String: Any]], semester: String, dropped: Set<String>, userAdded: [SDCourse],
        liveAnswer: CourseSelectionService.LiveAnswer? = nil
    ) -> [[String: Any]] {
        let addedHere = Set(userAdded.filter {
            $0.moodleIdNumber == nil && CourseStore.userAddedCourse($0, belongsTo: semester)
        }.map(\.courseNo))
        let dropped = dropped.union(droppedOnServer(rows, liveAnswer: liveAnswer))
        return rows.filter { row in
            let courseNo = row["course_no"] as? String ?? ""
            return isFiled(row, under: semester)
                && (!dropped.contains(courseNo) || addedHere.contains(courseNo) || row["source"] as? String == "user_added")
        }
    }

    /// The courses a roster dropped on the server, less one course selection here listed live
    /// after the drop: this device's roster puts it back. A row without `enrollment_status` counts
    /// as enrolled, and an answer within the clock skew margin of the drop counts as older.
    static func droppedOnServer(
        _ rows: [[String: Any]], liveAnswer: CourseSelectionService.LiveAnswer? = nil
    ) -> Set<String> {
        Set(rows.compactMap { row in
            guard row["enrollment_status"] as? String == "dropped", let courseNo = row["course_no"] as? String
            else { return nil }
            guard let liveAnswer, liveAnswer.courseNos.contains(courseNo), let droppedAt = FullSyncRunner.backendDate(row["updated_at"]),
                  liveAnswer.at > droppedAt.addingTimeInterval(CloudSyncCoordinator.clockSkewMargin)
            else { return courseNo }
            return nil
        })
    }

    static func isFiled(_ row: [String: Any], under semester: String) -> Bool {
        guard semester.count == 4,
              let moodleId = row["moodle_id"] as? String,
              let prefix = AcademicTerm.codePrefix(ofMoodleId: moodleId) else { return true }
        return prefix == semester.uppercased()
    }

    /// A hand-added course without class times, filled in from its server row. It keeps its own
    /// Moodle ID: a course added here has none, which tells it apart from one merged from the server.
    static func scheduled(_ existing: SDCourse, fromServerRow row: [String: Any]) -> SDCourse {
        let filled = course(fromServerRow: row, courseNo: existing.courseNo,
                            semester: existing.semester, name: existing.courseName,
                            dimension: existing.dimension, allYear: existing.allYear,
                            requireOption: existing.requireOption)
        filled.moodleIdNumber = existing.moodleIdNumber
        return filled
    }

    static func course(fromServerRow row: [String: Any], courseNo: String, semester: String, name: String?,
                               dimension: String = "", allYear: String = "",
                               requireOption: String = "") -> SDCourse {
        var schedule: [Int: [String]] = [:]
        for (key, periods) in (row["schedule_json"] as? [String: [String]]) ?? [:] {
            if let weekday = Int(key) { schedule[weekday] = periods }
        }
        return SDCourse(
            courseNo: courseNo,
            courseName: name ?? row["course_name"] as? String ?? courseNo,
            instructor: (row["instructors"] as? [String])?.joined(separator: ", ") ?? "",
            credits: row["credits"] as? Double ?? 0,
            classroom: row["classroom"] as? String ?? "",
            enrolledCount: row["enrolled_count"] as? Int ?? 0,
            maxCount: row["max_count"] as? Int ?? 0,
            schedule: schedule,
            moodleIdNumber: row["moodle_id"] as? String,
            semester: semester,
            classroomMap: row["classroom_map"] as? [String: String] ?? [:],
            dimension: dimension,
            allYear: allYear,
            requireOption: requireOption
        )
    }
}
