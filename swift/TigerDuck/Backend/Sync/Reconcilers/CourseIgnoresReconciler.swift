import Defaults
import Foundation
import os

@MainActor
struct CourseIgnoresReconciler: CategoryReconciler {
    static let category = "course_ignores"
    unowned let app: AppEnvironment

    func reconcile(_ pass: FullSyncPass) -> Bool {
        guard pass.marksLeftFor == nil, let server = pass.serverIgnoredCourses, Defaults[.syncCourses] else {
            return false
        }
        return applyIgnoredCourses(
            server, decided: Self.serverDecidedCourses(pass.courseOverrides),
            coursesArray: pass.coursesArray, protected: pass.protected, deleting: pass.courseDeletes,
            fetchedAt: pass.fetchedAt, for: pass.signIn
        )
    }

    nonisolated struct ServerIgnoredCourse: Equatable {
        let semester: String
        let courseNo: String
        let moodleId: String?
        let moodleCourseId: Int?

        var key: String { CourseTombstone.key(semester: semester, courseNo: courseNo) }
    }

    nonisolated static func serverIgnoredCourses(
        _ overrides: [[String: Any]],
        syncsCourses: Bool
    ) -> [ServerIgnoredCourse]? {
        guard syncsCourses, overrides.allSatisfy({ $0["ignore_assignments"] != nil }) else { return nil }
        return overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return ServerIgnoredCourse(
                semester: semester,
                courseNo: courseNo,
                moodleId: row["moodle_id"] as? String ?? (row["moodle_id"] as? Int).map(String.init),
                moodleCourseId: row["moodle_course_id"] as? Int
            )
        }
    }

    nonisolated static func mergedIgnoredCourses(
        server: Set<String>,
        local: Set<String>,
        protected: Set<String>,
        snapshotSemesters: Set<String>
    ) -> Set<String> {
        let isCovered = { (key: String) in
            CourseTombstone.parts(of: key).map { snapshotSemesters.contains($0.semester) } ?? false
        }
        return local.filter { !isCovered($0) }.union(AssignmentMarksReconciler.mergedMarks(
            server: server.filter(isCovered),
            local: local.filter(isCovered),
            protected: protected
        ))
    }

    nonisolated static func courseIgnoresToClear(
        server: [ServerIgnoredCourse],
        local: Set<String>
    ) -> [ServerIgnoredCourse] {
        server.filter { !local.contains($0.key) }
    }

    nonisolated static func serverDecidedCourses(_ overrides: [[String: Any]]) -> Set<String> {
        Set(overrides.compactMap { row in
            guard row["ignore_assignments"] as? Bool == true || row["ignore_assignments_updated_at"] is String,
                  let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

    nonisolated static func listedCourseRows(_ courses: [[String: Any]]) -> [String: Int] {
        var rows: [String: Int] = [:]
        for row in courses {
            guard let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty,
                  let id = row["id"] as? Int
            else { continue }
            rows[CourseTombstone.key(semester: semester, courseNo: courseNo)] = id
        }
        return rows
    }

    nonisolated static func recreatedCourses(listed: [String: Int], seen: [String: Int]) -> Set<String> {
        let survivingTerms = Set(listed.compactMap { key, id in
            seen[key] == id ? CourseTombstone.parts(of: key)?.semester : nil
        })
        return Set(listed.compactMap { key, id in
            guard let old = seen[key], old != id,
                  let semester = CourseTombstone.parts(of: key)?.semester, survivingTerms.contains(semester)
            else { return nil }
            return key
        })
    }

    nonisolated static func listedCourses(_ courses: [[String: Any]]) -> Set<String> {
        Set(courses.compactMap { row in
            guard let semester = row["semester"] as? String, !semester.isEmpty,
                  let courseNo = row["course_no"] as? String, !courseNo.isEmpty
            else { return nil }
            return CourseTombstone.key(semester: semester, courseNo: courseNo)
        })
    }

    nonisolated static func courseKeysPullLeaves(
        _ keys: Set<String>,
        deleting: Set<String>,
        resetSemesters: Set<String>
    ) -> Set<String> {
        keys.filter { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return false }
            return CourseTombstone.isHidden(courseNo, semester: semester, in: deleting) || resetSemesters.contains(semester)
        }
    }

    nonisolated static func ignoredCoursesAfterPull(
        server: Set<String>,
        decided: Set<String>,
        listed: Set<String>,
        local: Set<String>,
        protected: Set<String>,
        snapshotSemesters: Set<String>
    ) -> (ignored: Set<String>, resend: Set<String>) {
        let resend = local.intersection(listed).subtracting(decided).subtracting(protected)
        let ignored = mergedIgnoredCourses(
            server: server, local: local, protected: protected.union(resend), snapshotSemesters: snapshotSemesters
        )
        return (ignored, resend)
    }

    nonisolated static func ignoredCoursesDiffer(
        server: Set<String>?,
        decided: Set<String>,
        listed: Set<String>,
        local: Set<String>,
        snapshotSemesters: Set<String>
    ) -> Bool {
        guard let server else { return false }
        return ignoredCoursesAfterPull(
            server: server, decided: decided, listed: listed, local: local, protected: [],
            snapshotSemesters: snapshotSemesters
        ).ignored != local
    }

    static func moodleCourseIdsToSend(
        _ server: [ServerIgnoredCourse],
        protected: Set<String>,
        lookup: (String) -> Int?
    ) -> [(course: ServerIgnoredCourse, moodleId: String, moodleCourseId: Int)] {
        server.compactMap { course in
            guard course.moodleCourseId == nil, !protected.contains(course.key),
                  let moodleId = course.moodleId, let moodleCourseId = lookup(moodleId)
            else { return nil }
            return (course, moodleId, moodleCourseId)
        }
    }

    private func applyIgnoredCourses(
        _ server: [ServerIgnoredCourse],
        decided: Set<String>,
        coursesArray: [[String: Any]],
        protected: Set<String>,
        deleting queuedDeletes: Set<String>,
        fetchedAt: Date,
        for signIn: SignIn
    ) -> Bool {
        let now = Date()
        let deleting = app.localEdits.recentCourseDeletions.filter { now.timeIntervalSince($0.value) < LocalEdits.courseDeleteGraceInterval }
        let resetSemesters = app.localEdits.resettingSemesters.union(
            CourseStore.shared.loadSemesterResetAt().filter { $0.value > fetchedAt }.keys
        )
        let current = AssignmentStore.shared.loadIgnoredAssignmentCourses()
        let listed = Self.listedCourses(coursesArray)
        let listedRows = Self.listedCourseRows(coursesArray)
        let recreated = Self.recreatedCourses(listed: listedRows, seen: Defaults[.courseRowIdsSeen])
        SyncProgress.noteCourseRows(listedRows, for: signIn)
        let protected = protected.union(Self.courseKeysPullLeaves(
            Set(server.map(\.key)).union(listed).union(current),
            deleting: Set(deleting.keys).union(queuedDeletes),
            resetSemesters: resetSemesters
        ))
        let missingIds = Self.moodleCourseIdsToSend(server, protected: protected) {
            CourseLookup.moodleCourseId(idnumber: $0)
        }
        for (course, moodleId, moodleCourseId) in missingIds {
            Task { [coordinator = app.cloudSyncCoordinator] in
                await coordinator.enqueueCourseIgnore(
                    semester: course.semester, courseNo: course.courseNo, moodleId: moodleId,
                    moodleCourseId: moodleCourseId, ignore: nil)
            }
        }
        if !missingIds.isEmpty { app.cloudSyncCoordinator.scheduleTick(after: 1) }

        let (merged, resend) = Self.ignoredCoursesAfterPull(
            server: Set(server.map(\.key)),
            decided: decided.union(recreated),
            listed: listed,
            local: current,
            protected: protected,
            snapshotSemesters: Set(coursesArray.compactMap { $0["semester"] as? String })
        )
        if !resend.isEmpty {
            AppLogger.sync.info("[syncOverrides] sending \(resend.count, privacy: .public) course settings the server lost again")
            app.edits.syncCourseIgnores(resend)
        }
        guard merged != current else { return false }
        AssignmentStore.shared.replaceIgnoredAssignmentCourses(merged, for: signIn)
        return true
    }
}
