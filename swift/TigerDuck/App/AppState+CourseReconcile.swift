import Foundation
import Defaults
import os

extension AppState {

    @discardableResult
    func reconcileCourses(
        serverRows: [[String: Any]], tombstones: [[String: Any]], deleting queuedDeletes: Set<String>,
        adding: Set<String>, fetchedAt: Date
    ) -> Bool {
        let rowsBySemester = Dictionary(grouping: serverRows) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        let tombstonesBySemester = Dictionary(grouping: tombstones) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        let semesters = Set(rowsBySemester.keys)
            .union(tombstonesBySemester.keys)
            .union(SemesterCatalog.availableSemesters())

        let selectionDropped = DataCache.shared.loadSelectionDroppedNos()
        var deletedNos = Set(DataCache.shared.loadDeletedCourseNos())
        var userAdded = DataCache.shared.loadUserAddedCourses()
        var deletedChanged = false
        var mergedSemesters = Set<String>()
        let graceNow = Date()
        recentCourseDeletions = recentCourseDeletions.filter {
            graceNow.timeIntervalSince($0.value) < Self.courseDeleteGraceInterval
        }
        let deleting = Set(recentCourseDeletions.keys).union(queuedDeletes)
        let resetAt = DataCache.shared.loadSemesterResetAt()
        DataCache.shared.clearSemesterResets(outlivedBy: fetchedAt)

        for semester in semesters.sorted() {
            if resettingSemesters.contains(semester) { continue }
            if let reset = resetAt[semester], reset > fetchedAt { continue }
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

            let tombstoned = (tombstonesBySemester[semester] ?? []).compactMap { tombstone -> String? in
                let ownReset = (tombstone["deleted_by_reset"] as? Bool ?? false)
                    && (tombstone["deleted_by_this_device"] as? Bool ?? false)
                return ownReset ? nil : tombstone["course_no"] as? String
            }
            let unlisted = Self.unlistedCourses(
                in: semester, listed: serverNos, tombstoned: Set(tombstoned),
                fetched: Set(localCourses.map(\.courseNo)),
                handAdded: Set(userAdded.filter { DataCache.userAddedCourse($0, belongsTo: semester) }.map(\.courseNo)),
                hidden: deletedNos, adding: adding
            )
            for courseNo in unlisted.hide { hide(courseNo) }

            guard !serverNos.isEmpty else {
                let uploadable = localCourses.filter { !isHidden($0.courseNo) }
                if !uploadable.isEmpty {
                    uploadCourses(uploadable, semester: semester, resend: true)
                    AppLogger.sync.info("[sync] \(semester, privacy: .public): server empty, uploaded \(uploadable.count, privacy: .public) local courses")
                }
                let manualBefore = userAdded.count
                userAdded.removeAll { $0.semester == semester && isHidden($0.courseNo) }
                if userAdded.count != manualBefore { mergedSemesters.insert(semester) }
                continue
            }

            let manualBefore = userAdded.count
            userAdded.removeAll { DataCache.userAddedCourse($0, belongsTo: semester) && unlisted.drop.contains($0.courseNo) }
            if userAdded.count != manualBefore { mergedSemesters.insert(semester) }

            if Self.unhideListedCourses(serverNos, semester: semester, deleting: deleting, in: &deletedNos) {
                deletedChanged = true
            }

            let localNames = Dictionary(localCourses.map { ($0.courseNo, $0.courseName) }, uniquingKeysWith: { first, _ in first })
            var knownNos = Set(localCourses.map(\.courseNo))
            for (index, existing) in userAdded.enumerated() where DataCache.userAddedCourse(existing, belongsTo: semester) {
                knownNos.insert(existing.courseNo)
                guard existing.schedule.isEmpty,
                      let row = rows.first(where: { $0["course_no"] as? String == existing.courseNo }),
                      !((row["schedule_json"] as? [String: [String]]) ?? [:]).isEmpty else { continue }
                userAdded[index] = Self.course(fromServerRow: row, courseNo: existing.courseNo,
                                               semester: existing.semester, name: existing.courseName,
                                               dimension: existing.dimension, allYear: existing.allYear,
                                               requireOption: existing.requireOption)
                mergedSemesters.insert(semester)
            }
            for row in rows {
                guard let courseNo = row["course_no"] as? String, !knownNos.contains(courseNo),
                      Self.mergesListedCourse(courseNo, semester: semester, hidden: deletedNos, deleting: deleting)
                else { continue }
                userAdded.append(Self.course(fromServerRow: row, courseNo: courseNo,
                                             semester: semester, name: localNames[courseNo]))
                knownNos.insert(courseNo)
                mergedSemesters.insert(semester)
                AppLogger.sync.info("[sync] \(semester, privacy: .public): merged \(courseNo, privacy: .private) from server")
            }
        }

        if deletedChanged {
            DataCache.shared.saveDeletedCourseNos(Array(deletedNos))
        }
        guard !mergedSemesters.isEmpty else { return deletedChanged }
        DataCache.shared.saveUserAddedCourses(userAdded)
        Task {
            for semester in mergedSemesters {
                _ = await AppServiceBridge.refreshUserAddedCourses(semester: semester, authService: authService)
            }
            NotificationCenter.default.post(name: AppConstants.dataDidUpdate, object: nil)
        }
        return true
    }

    nonisolated static func unhideListedCourses(
        _ serverNos: Set<String>, semester: String, deleting: Set<String>, in deletedNos: inout Set<String>
    ) -> Bool {
        var changed = false
        for courseNo in serverNos where CourseTombstone.isHidden(courseNo, semester: semester, in: deletedNos)
            && !CourseTombstone.isHidden(courseNo, semester: semester, in: deleting) {
            CourseTombstone.unhide(courseNo, semester: semester, from: &deletedNos)
            changed = true
        }
        return changed
    }

    nonisolated static func mergesListedCourse(
        _ courseNo: String, semester: String, hidden: Set<String>, deleting: Set<String>
    ) -> Bool {
        !CourseTombstone.isHidden(courseNo, semester: semester, in: hidden)
            && !CourseTombstone.isHidden(courseNo, semester: semester, in: deleting)
    }

    nonisolated static func unlistedCourses(
        in semester: String,
        listed: Set<String>,
        tombstoned: Set<String>,
        fetched: Set<String>,
        handAdded: Set<String>,
        hidden: Set<String>,
        adding: Set<String>
    ) -> (hide: Set<String>, drop: Set<String>) {
        let isGone = { (courseNo: String) in
            !listed.contains(courseNo) && !adding.contains(CourseTombstone.key(semester: semester, courseNo: courseNo))
        }
        let isShown = { (courseNo: String) in !CourseTombstone.isHidden(courseNo, semester: semester, in: hidden) }
        let byTombstone = tombstoned.filter { isGone($0) && isShown($0) }
        guard !listed.isEmpty else { return (byTombstone, []) }
        return (byTombstone.union(fetched.filter { isGone($0) && isShown($0) }), handAdded.filter(isGone))
    }

    static func isFiled(_ row: [String: Any], under semester: String) -> Bool {
        guard semester.count == 4,
              let moodleId = row["moodle_id"] as? String,
              let prefix = SDCourse.semesterPrefix(ofMoodleId: moodleId) else { return true }
        return prefix == semester.uppercased()
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
