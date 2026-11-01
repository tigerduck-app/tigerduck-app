import Foundation
import TigerDuckCore

enum UserAddedOrigin {
    case addedHere
    case mergedFromServer
}

extension SDCourse {
    var userAddedOrigin: UserAddedOrigin { moodleIdNumber == nil ? .addedHere : .mergedFromServer }
}

nonisolated struct ServerTombstone {
    let courseNo: String?
    let isReset: Bool
    let hlc: Int64?

    init(_ row: [String: Any]) {
        courseNo = row["course_no"] as? String
        isReset = row["kind"] as? String == "reset"
        hlc = (row["hlc"] as? NSNumber)?.int64Value
    }

    func isOwnReset(landedAt resetLandedAt: Date?) -> Bool {
        guard isReset, let resetLandedAt, let hlc else { return false }
        return hlc <= PushAPI.clock(of: resetLandedAt)
    }
}

enum CourseServerRows {
    static func droppedMerges(_ userAdded: [SDCourse], semester: String, dropped: Set<String>) -> Set<String> {
        Set(userAdded.filter {
            $0.userAddedOrigin == .mergedFromServer && dropped.contains($0.courseNo)
                && CourseStore.userAddedCourse($0, belongsTo: semester)
        }.map(\.courseNo))
    }

    static func holdsAnyCourse(_ rows: [[String: Any]], listing listed: Set<String>) -> Bool {
        !listed.isEmpty || !droppedOnServer(rows).isEmpty
    }

    static func keptRows(
        _ rows: [[String: Any]], semester: String, dropped: Set<String>, userAdded: [SDCourse],
        liveAnswer: CourseSelectionService.LiveAnswer? = nil
    ) -> [[String: Any]] {
        let addedHere = Set(userAdded.filter {
            $0.userAddedOrigin == .addedHere && CourseStore.userAddedCourse($0, belongsTo: semester)
        }.map(\.courseNo))
        let dropped = dropped.union(droppedOnServer(rows, liveAnswer: liveAnswer))
        return rows.filter { row in
            let courseNo = row["course_no"] as? String ?? ""
            return isFiled(row, under: semester)
                && (!dropped.contains(courseNo) || addedHere.contains(courseNo) || row["source"] as? String == "user_added")
        }
    }

    static func droppedOnServer(
        _ rows: [[String: Any]], liveAnswer: CourseSelectionService.LiveAnswer? = nil
    ) -> Set<String> {
        Set(rows.compactMap { row in
            guard row["enrollment_status"] as? String == "dropped", let courseNo = row["course_no"] as? String,
                  !liveAnswerOutranksDrop(liveAnswer, of: courseNo, droppedAt: FullSyncRunner.backendDate(row["updated_at"]))
            else { return nil }
            return courseNo
        })
    }

    static func liveAnswerOutranksDrop(
        _ liveAnswer: CourseSelectionService.LiveAnswer?, of courseNo: String, droppedAt: Date?
    ) -> Bool {
        guard let liveAnswer, liveAnswer.courseNos.contains(courseNo), let droppedAt else { return false }
        return liveAnswer.at > droppedAt.addingTimeInterval(CloudSyncCoordinator.clockSkewMargin)
    }

    static func isFiled(_ row: [String: Any], under semester: String) -> Bool {
        guard semester.count == 4,
              let moodleId = row["moodle_id"] as? String,
              let prefix = AcademicTerm.codePrefix(ofMoodleId: moodleId) else { return true }
        return prefix == semester.uppercased()
    }

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
