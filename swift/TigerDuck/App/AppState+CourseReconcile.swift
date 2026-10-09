// Course reconcile against the backend snapshot. Each known term is reconciled on its own, so a
// retaken course number can be hidden in one semester and shown in another, and nothing has to
// guess which term is "current" or "newest".

import Foundation
import Defaults
import os

extension AppState {

    /// Applies the server's course list to the local caches, one semester
    /// at a time. `serverRows` is the `courses` array of `/sync/full`,
    /// `tombstones` its `course_tombstones`, `fetchedAt` when the request
    /// went out — what the snapshot is as of.
    func reconcileCourses(serverRows: [[String: Any]], tombstones: [[String: Any]], fetchedAt: Date) {
        // Client-uploaded rows carry the term they belong to. The server's
        // own Moodle mirror rows ("moodle:" keys) carry "" and are not a
        // roster, so they drop out here.
        let rowsBySemester = Dictionary(grouping: serverRows) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        let tombstonesBySemester = Dictionary(grouping: tombstones) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        // After a reset the rows are exactly what is gone, so a term may be
        // known only by its tombstones.
        let semesters = Set(rowsBySemester.keys)
            .union(tombstonesBySemester.keys)
            .union(SemesterCatalog.availableSemesters())

        let selectionDropped = DataCache.shared.loadSelectionDroppedNos()
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
        // A term mid-reset, or one this device reset after this snapshot
        // was fetched — the snapshot still carries the pre-reset roster.
        // See `resettingSemesters` and `DataCache.loadSemesterResetAt`.
        let resetAt = DataCache.shared.loadSemesterResetAt()
        DataCache.shared.clearSemesterResets(outlivedBy: fetchedAt)

        for semester in semesters.sorted() {
            if resettingSemesters.contains(semester) { continue }
            if let reset = resetAt[semester], reset > fetchedAt { continue }
            // Skip misfiled rows and courses dropped in course selection: neither is a roster nor
            // evidence of presence, though uploads only upsert and leave the latter on the server.
            // Kept, they would undo hand deletions and join `userAdded`, which portal refreshes keep.
            let droppedHere = Set(selectionDropped[semester] ?? [])
            let rows = (rowsBySemester[semester] ?? []).filter {
                Self.isFiled($0, under: semester)
                    && !droppedHere.contains(($0["course_no"] as? String) ?? "")
            }
            let serverNos = Set(rows.compactMap { $0["course_no"] as? String })
            let localCourses = DataCache.shared.loadCourses(semester: semester)

            func isHidden(_ courseNo: String) -> Bool {
                CourseTombstone.isHidden(courseNo, semester: semester, in: deletedNos)
            }
            func hide(_ courseNo: String) {
                deletedNos.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
                deletedChanged = true
            }

            // Apply tombstones before any emptiness check: a reset empties the term and tombstones
            // each course, and reading the silence first would keep the old roster.
            // See docs/decisions/0005-course-tombstones.md.
            for tombstone in tombstonesBySemester[semester] ?? [] {
                guard let courseNo = tombstone["course_no"] as? String,
                      !serverNos.contains(courseNo), !isHidden(courseNo) else { continue }
                // This device's own reset tombstones are skipped: its next upload releases them.
                // Hiding the courses would leave the reset's refetch, which filters by the
                // tombstone store, nothing to upload, so the tombstones would never be released.
                let ownReset = (tombstone["deleted_by_reset"] as? Bool ?? false)
                    && (tombstone["deleted_by_this_device"] as? Bool ?? false)
                if ownReset { continue }
                hide(courseNo)
            }

            // Empty term on the server (first sync, or another device mid-reset): upload what the
            // tombstones leave visible instead of treating every local course as deleted elsewhere.
            // After a reset that is nothing; tombstoned manual courses go as in the branch below.
            guard !serverNos.isEmpty else {
                let uploadable = localCourses.filter { !isHidden($0.courseNo) }
                if !uploadable.isEmpty {
                    uploadCourses(uploadable, semester: semester)
                    AppLogger.sync.info("[sync] \(semester, privacy: .public): server empty, uploaded \(uploadable.count, privacy: .public) local courses")
                }
                // Only rows stamped with this term: an unstamped legacy row
                // reads as belonging to every term, and a tombstone here
                // says nothing about it.
                let manualBefore = userAdded.count
                userAdded.removeAll { $0.semester == semester && isHidden($0.courseNo) }
                if userAdded.count != manualBefore { mergedSemesters.insert(semester) }
                continue
            }

            // Portal course absent from the server → deleted on another device.
            for course in localCourses where !serverNos.contains(course.courseNo) && !isHidden(course.courseNo) {
                hide(course.courseNo)
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
                                               semester: existing.semester, name: existing.courseName,
                                               dimension: existing.dimension, allYear: existing.allYear)
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

    /// Whether a server row really belongs to `semester`. A row whose Moodle id names
    /// another term ("1151CS…" filed under 1142) is left over from a bug that uploaded
    /// next-term enrolments from course selection under the heuristic current term. It is
    /// not a roster: never merge it or count it as "on the server".
    static func isFiled(_ row: [String: Any], under semester: String) -> Bool {
        guard semester.count == 4,
              let moodleId = row["moodle_id"] as? String,
              let prefix = SDCourse.semesterPrefix(ofMoodleId: moodleId) else { return true }
        // Both sides normalised: a summer term reaches us as "114H" from
        // NTUST and "114h" from Moodle, and a raw compare filed every
        // summer row under "another term".
        return prefix == semester.uppercased()
    }

    /// Known gap: the sync payload has no `dimension` or `all_year`, so a row merged from
    /// another device leaves both empty and the detail sheet hides those two rows. The next
    /// QueryCourse refresh fills them in for a current term; for a term the portal has stopped
    /// serving they stay empty until the backend sends them.
    ///
    /// Callers rebuilding a row they already hold must pass the values it carries: a local
    /// record that saw QueryCourse knows its dimension and the server row does not, so the
    /// defaults would erase that metadata during a schedule merge.
    static func course(fromServerRow row: [String: Any], courseNo: String, semester: String, name: String?,
                               dimension: String = "", allYear: String = "") -> SDCourse {
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
            allYear: allYear
        )
    }
}
