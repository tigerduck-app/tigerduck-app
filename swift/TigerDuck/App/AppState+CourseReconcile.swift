import Foundation
import Defaults
import os

extension AppState {

    /// Applies a course reset made elsewhere before the snapshot's courses are reconciled, and
    /// returns the deletes the reconcile still has to wait for, or nil when the full sync may no
    /// longer write; the reset then stays unseen and the next full sync applies it.
    func settleQueuedCourseEdits(
        deleting: Set<String>, reset: (apply: Bool, remember: Date), generation: Int
    ) async -> Set<String>? {
        guard reset.apply else { return deleting }
        guard let dropped = await Self.applyCourseReset(
            at: reset.remember, cache: .shared, on: cloudSyncCoordinator,
            mayWrite: { self.fullSyncMayWrite(since: generation) }
        ) else { return nil }
        Defaults[.lastSeenCoursesResetAt] = reset.remember
        recentCourseDeletions = [:]
        AppLogger.sync.info("[sync] courses reset detected (reset=\(String(describing: reset.remember), privacy: .public)), wiped local state")
        return deleting.subtracting(dropped)
    }

    /// Drops the course edits queued before a reset made elsewhere and wipes the hand-added and
    /// hidden courses, but keeps those whose add or delete made after it still goes out, as the
    /// add uploads its course from them. Returns the keys of the dropped deletes, or nil, with the
    /// caches untouched, when `mayWrite` says no after the hops, as behind the lock screen, where
    /// the protected course files read as empty.
    static func applyCourseReset(
        at resetAt: Date, cache: DataCache, on coordinator: CloudSyncCoordinator, mayWrite: () -> Bool
    ) async -> Set<String>? {
        let dropped = await coordinator.dropCourseEdits(madeBeforeReset: resetAt)
        let adding = await coordinator.courseAddKeys(unlandedAt: resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin))
        let deleting = await coordinator.pendingCourseDeleteKeys()
        guard mayWrite() else { return nil }
        let added = adding.compactMap(CourseTombstone.parts(of:))
        cache.saveUserAddedCourses(cache.loadUserAddedCourses().filter { course in
            added.contains { $0.courseNo == course.courseNo && DataCache.userAddedCourse(course, belongsTo: $0.semester) }
        })
        cache.saveDeletedCourseNos(cache.loadDeletedCourseNos().filter(deleting.contains))
        return dropped
    }

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
            let handAdded = Set(userAdded.filter { DataCache.userAddedCourse($0, belongsTo: semester) }.map(\.courseNo))
            let termRows = rowsBySemester[semester] ?? []
            let droppedOnServer = Self.droppedOnServer(termRows)
            let dropped = Set(selectionDropped[semester] ?? [])
            let rows = Self.keptRows(termRows, semester: semester, dropped: dropped, userAdded: userAdded)
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
                // A course this device's own course selection fetched leaves with its next roster:
                // a hide would outlive a drop that roster undoes.
                fetched: Set(localCourses.map(\.courseNo)).subtracting(droppedOnServer),
                handAdded: handAdded,
                droppedMerges: Self.droppedMerges(userAdded, semester: semester, dropped: dropped.union(droppedOnServer)),
                hidden: deletedNos, adding: adding
            )
            for courseNo in unlisted.hide { hide(courseNo) }
            let manualBefore = userAdded.count
            userAdded.removeAll { DataCache.userAddedCourse($0, belongsTo: semester) && unlisted.drop.contains($0.courseNo) }

            guard !serverNos.isEmpty else {
                let uploadable = localCourses.filter { !isHidden($0.courseNo) }
                if !uploadable.isEmpty {
                    uploadCourses(uploadable, semester: semester, resend: true)
                    AppLogger.sync.info("[sync] \(semester, privacy: .public): server empty, uploaded \(uploadable.count, privacy: .public) local courses")
                }
                userAdded.removeAll { $0.semester == semester && isHidden($0.courseNo) }
                if userAdded.count != manualBefore { mergedSemesters.insert(semester) }
                continue
            }
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
                userAdded[index] = Self.scheduled(existing, fromServerRow: row)
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

    /// A hand-added course leaves once the server stops listing it. When the server lists none of
    /// the term's, only one in `droppedMerges` does: any other may not have reached the server yet.
    nonisolated static func unlistedCourses(
        in semester: String,
        listed: Set<String>,
        tombstoned: Set<String>,
        fetched: Set<String>,
        handAdded: Set<String>,
        droppedMerges: Set<String>,
        hidden: Set<String>,
        adding: Set<String>
    ) -> (hide: Set<String>, drop: Set<String>) {
        let isGone = { (courseNo: String) in
            !listed.contains(courseNo) && !adding.contains(CourseTombstone.key(semester: semester, courseNo: courseNo))
        }
        let isShown = { (courseNo: String) in !CourseTombstone.isHidden(courseNo, semester: semester, in: hidden) }
        let byTombstone = tombstoned.filter { isGone($0) && isShown($0) }
        guard !listed.isEmpty else { return (byTombstone, droppedMerges.filter(isGone)) }
        return (byTombstone.union(fetched.filter { isGone($0) && isShown($0) }), handAdded.filter(isGone))
    }

    /// The term's courses merged from the server that were dropped. One added by hand here has no
    /// Moodle ID; one added on another device keeps its `user_added` row in `keptRows`.
    static func droppedMerges(_ userAdded: [SDCourse], semester: String, dropped: Set<String>) -> Set<String> {
        Set(userAdded.filter {
            $0.moodleIdNumber != nil && dropped.contains($0.courseNo) && DataCache.userAddedCourse($0, belongsTo: semester)
        }.map(\.courseNo))
    }

    /// The term's server rows, less those of courses course selection here dropped or a roster
    /// dropped on the server. A course the user added by hand keeps its row, so a drop never takes
    /// it out of the hand-added courses: one added here has no Moodle ID, which a row merged from the
    /// server always has, and one added on another device is a `user_added` row.
    static func keptRows(
        _ rows: [[String: Any]], semester: String, dropped: Set<String>, userAdded: [SDCourse]
    ) -> [[String: Any]] {
        let addedHere = Set(userAdded.filter {
            $0.moodleIdNumber == nil && DataCache.userAddedCourse($0, belongsTo: semester)
        }.map(\.courseNo))
        let dropped = dropped.union(droppedOnServer(rows))
        return rows.filter { row in
            let courseNo = row["course_no"] as? String ?? ""
            return isFiled(row, under: semester)
                && (!dropped.contains(courseNo) || addedHere.contains(courseNo) || row["source"] as? String == "user_added")
        }
    }

    /// The courses a roster dropped on the server. A row without `enrollment_status` counts as
    /// enrolled.
    static func droppedOnServer(_ rows: [[String: Any]]) -> Set<String> {
        Set(rows.compactMap { $0["enrollment_status"] as? String == "dropped" ? $0["course_no"] as? String : nil })
    }

    static func isFiled(_ row: [String: Any], under semester: String) -> Bool {
        guard semester.count == 4,
              let moodleId = row["moodle_id"] as? String,
              let prefix = SDCourse.semesterPrefix(ofMoodleId: moodleId) else { return true }
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
