import Foundation
import os
import TigerDuckCore

@MainActor
struct CourseRosterReconciler: CategoryReconciler {
    unowned let app: AppEnvironment

    func reconcile(_ pass: FullSyncPass) -> Bool {
        defer { CourseUpload.answerRosterRequests(in: pass.json, authService: app.authService, for: pass.signIn) }
        guard pass.taken.contains(.courses) else {
            if pass.policy.pendingChecks.contains(.courses) {
                AppLogger.sync.info("[syncOverrides] skipping course sync — conflict check pending")
            }
            return false
        }
        return reconcileCourses(
            serverRows: pass.coursesArray, tombstones: pass.json["course_tombstones"] as? [[String: Any]] ?? [],
            deleting: pass.courseDeletes, adding: pass.courseAdds, fetchedAt: pass.fetchedAt, for: pass.signIn
        )
    }

    @discardableResult
    private func reconcileCourses(
        serverRows: [[String: Any]], tombstones: [[String: Any]], deleting queuedDeletes: Set<String>,
        adding: Set<String>, fetchedAt: Date, for signIn: SignIn
    ) -> Bool {
        let rowsBySemester = Dictionary(grouping: serverRows) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        let tombstonesBySemester = Dictionary(grouping: tombstones) { ($0["semester"] as? String) ?? "" }
            .filter { !$0.key.isEmpty }
        let semesters = Set(rowsBySemester.keys)
            .union(tombstonesBySemester.keys)
            .union(SemesterCatalog.availableSemesters())

        let selectionDropped = CourseStore.shared.loadSelectionDroppedNos()
        let studentId = app.authService.storedStudentId
        var coursesLeft = false
        var deletedNos = Set(CourseStore.shared.loadDeletedCourseNos())
        var userAdded = CourseStore.shared.loadUserAddedCourses()
        var deletedChanged = false
        var mergedSemesters = Set<String>()
        let graceNow = Date()
        app.localEdits.setRecentCourseDeletions(app.localEdits.recentCourseDeletions.filter {
            graceNow.timeIntervalSince($0.value) < LocalEdits.courseDeleteGraceInterval
        }, for: signIn)
        let deleting = Set(app.localEdits.recentCourseDeletions.keys).union(queuedDeletes)
        let resetAt = CourseStore.shared.loadSemesterResetAt()
        let ownResets = tombstonesBySemester.filter { semester, tombstones in
            tombstones.contains { ServerTombstone($0).isOwnReset(landedAt: resetAt[semester]) }
        }
        CourseStore.shared.clearSemesterResets(outlivedBy: fetchedAt, keeping: Set(ownResets.keys), for: signIn)

        for semester in semesters.sorted() {
            if app.localEdits.resettingSemesters.contains(semester) { continue }
            if let reset = resetAt[semester], reset > fetchedAt { continue }
            let term = Self.readTerm(
                semester, rows: rowsBySemester[semester] ?? [], tombstones: tombstonesBySemester[semester] ?? [],
                selectionDropped: Set(selectionDropped[semester] ?? []), userAdded: userAdded, hidden: deletedNos,
                adding: adding, resetLandedAt: resetAt[semester],
                liveAnswer: studentId.flatMap { CourseSelectionService.lastAnswer(studentId: $0, semester: semester) },
                courses: .shared
            )
            Self.recordServerDrops(of: term, semester: semester, courses: .shared, for: signIn) {
                if let studentId { CourseSelectionService.invalidateEnrolledCoursesCache(for: studentId) }
            }
            let (rows, serverNos, localCourses, unlisted) = (term.rows, term.serverNos, term.localCourses, term.unlisted)
            if !term.left.isEmpty {
                coursesLeft = true
                AppLogger.sync.info("[sync] \(semester, privacy: .public): \(term.left.count, privacy: .public) dropped courses left")
            }

            func isHidden(_ courseNo: String) -> Bool {
                CourseTombstone.isHidden(courseNo, semester: semester, in: deletedNos)
            }
            func hide(_ courseNo: String) {
                deletedNos.insert(CourseTombstone.key(semester: semester, courseNo: courseNo))
                deletedChanged = true
            }

            for courseNo in unlisted.hide { hide(courseNo) }
            let manualBefore = userAdded.count
            userAdded.removeAll { CourseStore.userAddedCourse($0, belongsTo: semester) && unlisted.drop.contains($0.courseNo) }

            guard !term.serverHoldsNothing else {
                let uploadable = localCourses.filter { !isHidden($0.courseNo) }
                if !uploadable.isEmpty {
                    app.uploads.uploadCourses(uploadable, semester: semester, resend: true, for: signIn)
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
            for (index, existing) in userAdded.enumerated() where CourseStore.userAddedCourse(existing, belongsTo: semester) {
                knownNos.insert(existing.courseNo)
                guard existing.schedule.isEmpty,
                      let row = rows.first(where: { $0["course_no"] as? String == existing.courseNo }),
                      !((row["schedule_json"] as? [String: [String]]) ?? [:]).isEmpty else { continue }
                userAdded[index] = CourseServerRows.scheduled(existing, fromServerRow: row)
                mergedSemesters.insert(semester)
            }
            for row in rows {
                guard let courseNo = row["course_no"] as? String, !knownNos.contains(courseNo),
                      Self.mergesListedCourse(courseNo, semester: semester, hidden: deletedNos, deleting: deleting)
                else { continue }
                userAdded.append(CourseServerRows.course(fromServerRow: row, courseNo: courseNo,
                                             semester: semester, name: localNames[courseNo]))
                knownNos.insert(courseNo)
                mergedSemesters.insert(semester)
                AppLogger.sync.info("[sync] \(semester, privacy: .public): merged \(courseNo, privacy: .private) from server")
            }
        }

        if deletedChanged {
            CourseStore.shared.saveDeletedCourseNos(Array(deletedNos), for: signIn)
        }
        guard !mergedSemesters.isEmpty else { return deletedChanged || coursesLeft }
        CourseStore.shared.saveUserAddedCourses(userAdded, for: signIn)
        Task {
            for semester in mergedSemesters {
                _ = await CourseDetails.refreshUserAddedCourses(semester: semester, for: signIn)
            }
        }
        return true
    }

    struct TermRead {
        let rows: [[String: Any]]
        let serverNos: Set<String>
        let localCourses: [SDCourse]
        let left: Set<String>
        let unlisted: (hide: Set<String>, drop: Set<String>)
        let serverHoldsNothing: Bool
        let droppedOnServer: Set<String>
        let liveAnswerListsADrop: Bool
    }

    static func readTerm(
        _ semester: String, rows termRows: [[String: Any]], tombstones: [[String: Any]],
        selectionDropped: Set<String>, userAdded: [SDCourse], hidden: Set<String>, adding: Set<String>,
        resetLandedAt: Date? = nil, liveAnswer: CourseSelectionService.LiveAnswer?, courses: CourseStore
    ) -> TermRead {
        let droppedOnServer = CourseServerRows.droppedOnServer(termRows, liveAnswer: liveAnswer)
        let rows = CourseServerRows.keptRows(
            termRows, semester: semester, dropped: selectionDropped, userAdded: userAdded, liveAnswer: liveAnswer
        )
        let serverNos = Set(rows.compactMap { $0["course_no"] as? String })
        let fetched = courses.loadCourses(semester: semester)
        let localCourses = fetched.filter { !droppedOnServer.contains($0.courseNo) }
        let left = Set(fetched.map(\.courseNo)).subtracting(localCourses.map(\.courseNo))
        let read = tombstones.map(ServerTombstone.init)
        let tombstoned = read.compactMap { tombstone in
            tombstone.isRemoval || tombstone.isOwnReset(landedAt: resetLandedAt) ? nil : tombstone.courseNo
        }
        let unlisted = unlistedCourses(
            in: semester, listed: serverNos, tombstoned: Set(tombstoned),
            removed: Set(read.compactMap { $0.isRemoval ? $0.courseNo : nil }),
            fetched: Set(localCourses.map(\.courseNo)),
            handAdded: Set(userAdded.filter { CourseStore.userAddedCourse($0, belongsTo: semester) }.map(\.courseNo)),
            droppedMerges: CourseServerRows.droppedMerges(userAdded, semester: semester, dropped: selectionDropped.union(droppedOnServer)),
            hidden: hidden, adding: adding
        )
        return TermRead(
            rows: rows, serverNos: serverNos, localCourses: localCourses, left: left, unlisted: unlisted,
            serverHoldsNothing: !CourseServerRows.holdsAnyCourse(termRows, listing: serverNos),
            droppedOnServer: droppedOnServer,
            liveAnswerListsADrop: liveAnswer?.courseNos.contains(where: droppedOnServer.contains) == true
        )
    }

    static func recordServerDrops(
        of term: TermRead, semester: String, courses: CourseStore, for signIn: SignIn, forgetAnswer: () -> Void
    ) {
        courses.saveServerDroppedNos(term.droppedOnServer, semester: semester, for: signIn)
        courses.removeCourses(term.droppedOnServer, semester: semester, for: signIn)
        if term.liveAnswerListsADrop { forgetAnswer() }
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
        removed: Set<String> = [],
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
        let termMayNotHaveReachedServer = listed.isEmpty
        guard !termMayNotHaveReachedServer else {
            return (byTombstone, droppedMerges.union(handAdded.intersection(removed)).filter(isGone))
        }
        return (byTombstone.union(fetched.subtracting(removed).filter { isGone($0) && isShown($0) }), handAdded.filter(isGone))
    }

    static func reenableCourseNos(
        _ rows: [[String: Any]], semester: String, local: Set<String>, userAdded: [SDCourse],
        liveAnswer: CourseSelectionService.LiveAnswer?
    ) -> (server: Set<String>, local: Set<String>) {
        let termRows = rows.filter { $0["semester"] as? String == semester }
        let kept = CourseServerRows.keptRows(termRows, semester: semester, dropped: [], userAdded: userAdded, liveAnswer: liveAnswer)
        let server = Set(kept.compactMap { $0["course_no"] as? String })
        return (server, local.subtracting(CourseServerRows.droppedOnServer(termRows, liveAnswer: liveAnswer).subtracting(server)))
    }
}
