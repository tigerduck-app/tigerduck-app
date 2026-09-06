// Per-semester course reconcile against the backend snapshot — split out
// of AppState+BackendSync.swift.
//
// Every term the app knows about is reconciled on its own, so a retaken
// course number can be hidden in one semester and shown in another, and
// nothing has to guess which term is "current" or "newest".

import Foundation
import Defaults
import os

extension AppState {

    /// Applies the server's course list to the local caches, one semester
    /// at a time. `serverRows` is the `courses` array of `/sync/full`,
    /// `tombstones` its `course_tombstones`.
    func reconcileCourses(serverRows: [[String: Any]], tombstones: [[String: Any]]) {
        // Client-uploaded rows carry the term they belong to. The server's
        // own Moodle mirror rows ("moodle:" keys) carry "" and are not a
        // roster, so they drop out here.
        let rowsBySemester = Dictionary(grouping: serverRows) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        let tombstonesBySemester = Dictionary(grouping: tombstones) { ($0["semester"] as? String) ?? "" }
        let semesters = Set(rowsBySemester.keys).union(SemesterCatalog.availableSemesters())

        var deletedNos = Set(DataCache.shared.loadDeletedCourseNos())
        var userAdded = DataCache.shared.loadUserAddedCourses()
        var deletedChanged = false
        var mergedSemesters = Set<String>()
        // A course the user just deleted here must not flap back in before
        // the backend DELETE lands. Expire stale grace entries as we go.
        let graceNow = Date()
        recentCourseDeletions = recentCourseDeletions.filter {
            graceNow.timeIntervalSince($0.value) < Self.courseDeleteGraceInterval
        }

        for semester in semesters.sorted() {
            let rows = rowsBySemester[semester] ?? []
            let serverNos = Set(rows.compactMap { $0["course_no"] as? String })
            let localCourses = DataCache.shared.loadCourses(semester: semester)

            // Nothing uploaded for this term yet (first sync, or another
            // device is mid-reset): push what we have instead of treating
            // every local course as deleted elsewhere.
            guard !serverNos.isEmpty else {
                if !localCourses.isEmpty {
                    uploadCourses(localCourses, semester: semester)
                    AppLogger.sync.info("[sync] \(semester, privacy: .public): server empty, uploaded \(localCourses.count, privacy: .public) local courses")
                }
                continue
            }

            func isHidden(_ courseNo: String) -> Bool {
                CourseTombstone.isHidden(courseNo, semester: semester, in: deletedNos)
            }
            func hide(_ courseNo: String) {
                deletedNos.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
                deletedChanged = true
            }

            // Portal course absent from the server → deleted on another device.
            for course in localCourses where !serverNos.contains(course.courseNo) && !isHidden(course.courseNo) {
                hide(course.courseNo)
            }
            // Explicit tombstones from other devices.
            for tombstone in tombstonesBySemester[semester] ?? [] {
                guard let courseNo = tombstone["course_no"] as? String,
                      !serverNos.contains(courseNo), !isHidden(courseNo) else { continue }
                hide(courseNo)
            }
            // Manual additions the server no longer lists.
            let manualBefore = userAdded.count
            userAdded.removeAll { DataCache.userAddedCourse($0, belongsTo: semester) && !serverNos.contains($0.courseNo) }
            if userAdded.count != manualBefore { mergedSemesters.insert(semester) }

            // Hidden here but back on the server → un-hide, unless our own
            // delete is still in flight.
            for courseNo in serverNos where isHidden(courseNo) && recentCourseDeletions[courseNo] == nil {
                CourseTombstone.unhide(courseNo, semester: semester, from: &deletedNos)
                deletedChanged = true
            }

            // Server rows missing locally → keep them as user-added so a
            // portal refresh (which overwrites the main cache) can't drop them.
            let localNames = Dictionary(localCourses.map { ($0.courseNo, $0.courseName) }, uniquingKeysWith: { first, _ in first })
            var knownNos = Set(localCourses.map(\.courseNo))
            for (index, existing) in userAdded.enumerated() where DataCache.userAddedCourse(existing, belongsTo: semester) {
                knownNos.insert(existing.courseNo)
                // A manual row saved without a schedule picks one up from the server.
                guard existing.schedule.isEmpty,
                      let row = rows.first(where: { $0["course_no"] as? String == existing.courseNo }),
                      !((row["schedule_json"] as? [String: [String]]) ?? [:]).isEmpty else { continue }
                userAdded[index] = Self.course(fromServerRow: row, courseNo: existing.courseNo,
                                               semester: existing.semester, name: existing.courseName)
                mergedSemesters.insert(semester)
            }
            for row in rows {
                guard let courseNo = row["course_no"] as? String,
                      !knownNos.contains(courseNo), !isHidden(courseNo) else { continue }
                userAdded.append(Self.course(fromServerRow: row, courseNo: courseNo,
                                             semester: semester, name: localNames[courseNo]))
                knownNos.insert(courseNo)
                mergedSemesters.insert(semester)
                AppLogger.sync.info("[sync] \(semester, privacy: .public): merged \(courseNo, privacy: .public) from server")
            }
        }

        if deletedChanged {
            DataCache.shared.saveDeletedCourseNos(Array(deletedNos))
        }
        guard !mergedSemesters.isEmpty else { return }
        DataCache.shared.saveUserAddedCourses(userAdded)
        // Rows merged from the server carry whatever the other device
        // uploaded; re-query them so names, rooms and headcounts match this
        // device's language and today's roster.
        Task {
            for semester in mergedSemesters {
                _ = await AppServiceBridge.refreshUserAddedCourses(semester: semester)
            }
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        }
    }

    private static func course(fromServerRow row: [String: Any], courseNo: String, semester: String, name: String?) -> SDCourse {
        var schedule: [Int: [String]] = [:]
        for (key, periods) in (row["schedule_json"] as? [String: [String]]) ?? [:] {
            if let weekday = Int(key) { schedule[weekday] = periods }
        }
        return SDCourse(
            courseNo: courseNo,
            courseName: name ?? row["course_name"] as? String ?? courseNo,
            instructor: (row["instructors"] as? [String])?.joined(separator: ", ") ?? "",
            credits: Int(row["credits"] as? Double ?? 0),
            classroom: row["classroom"] as? String ?? "",
            enrolledCount: row["enrolled_count"] as? Int ?? 0,
            maxCount: row["max_count"] as? Int ?? 0,
            schedule: schedule,
            moodleIdNumber: row["moodle_id"] as? String,
            semester: semester,
            classroomMap: row["classroom_map"] as? [String: String] ?? [:]
        )
    }
}
