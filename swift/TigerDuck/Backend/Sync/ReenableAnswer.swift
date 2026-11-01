import Foundation
import os

@MainActor
enum ReenableAnswer {
    typealias Conflict = SyncConflicts.ReenableConflict

    struct Effects {
        let signIn: SignIn
        let take: (_ categories: [SyncCategory], _ keepLocal: Bool) -> Set<SyncCategory>
        let release: (_ held: Set<SyncCategory>) -> Void
        let end: (_ held: Set<SyncCategory>) -> Void
        let dropQueuedEdits: (_ categories: Set<SyncCategory>, _ courseIgnores: Bool) async -> Void
        let sendCourses: () async throws -> Void
        let markCoursesForCheck: () -> Void
        let queueEdits: () -> [Task<Void, Never>]
        let dropLocalCopies: () -> Void
        let syncFromServer: (_ followUpIfBusy: Bool) async -> Void
        let noteAnswered: (_ saveFailed: Bool) -> Void
    }

    static func answer(_ conflict: Conflict, keepLocal: Bool, effects: Effects) async {
        if !keepLocal {
            await effects.dropQueuedEdits(Set(conflict.categories), conflict.serverIgnoredCourses != nil)
        }
        guard effects.signIn.isCurrent else { return }
        let held = effects.take(conflict.categories, keepLocal)
        var coursesSaveFailed = false
        if keepLocal {
            defer { effects.end(held) }
            if conflict.categories.contains(.courses) {
                do {
                    try await effects.sendCourses()
                } catch {
                    AppLogger.sync.error("[reenable] keep-local course sync failed (server may be empty): \(error, privacy: .private)")
                    if effects.signIn.isCurrent { effects.markCoursesForCheck() }
                    coursesSaveFailed = true
                }
            }
            guard effects.signIn.isCurrent else { return }
            for task in effects.queueEdits() { await task.value }
            guard effects.signIn.isCurrent else { return }
            effects.release(held)
        } else {
            effects.dropLocalCopies()
            await effects.syncFromServer(true)
        }
        guard effects.signIn.isCurrent else { return }
        effects.noteAnswered(coursesSaveFailed)
    }

    static func sendLocalCourses(
        localEdits: LocalEdits, push: PushCoordinator, for signIn: SignIn
    ) async throws {
        guard SyncPolicy.current.uploadsCourses else { return }
        let terms = SemesterCatalog.availableSemesters().map { semester in
            (semester: semester,
             courses: CourseStore.shared.loadCourses(semester: semester)
                + CourseStore.shared.loadUserAddedCourses(semester: semester))
        }
        let latched = Set(terms.map(\.semester))
        localEdits.resettingSemesters.formUnion(latched)
        defer {
            localEdits.resettingSemesters.subtract(latched)
            for semester in latched { CourseStore.shared.recordSemesterReset(semester, for: signIn) }
        }
        try await keepLocalCourses(
            terms, hiding: Set(CourseStore.shared.loadDeletedCourseNos()), on: push, for: signIn
        )
    }

    static func queueLocalEdits(of conflict: Conflict, edits: EditSender, for signIn: SignIn) -> [Task<Void, Never>] {
        var queued: [Task<Void, Never>?] = []
        if conflict.categories.contains(.courseColors) || conflict.categories.contains(.courseNames) {
            let terms = SemesterCatalog.availableSemesters().map { ($0, CourseStore.shared.loadCourses(semester: $0)) }
            let moodleIdByCourseNo = Dictionary(
                terms.flatMap(\.1).compactMap { c in c.moodleIdNumber.map { (c.courseNo, $0) } },
                uniquingKeysWith: { first, _ in first })
            if conflict.categories.contains(.courseColors) {
                let identities = terms.flatMap { term in
                    term.1.map { ($0.courseNo, EditSender.colorIdentity(of: $0, semester: term.0)) }
                }
                let identityByCourseNo = moodleIdByCourseNo.merging(identities, uniquingKeysWith: { first, _ in first })
                let colorMap = TigerDuckTheme.courseColorMap
                for (courseNo, hex) in colorMap {
                    guard let identity = identityByCourseNo[courseNo] else { continue }
                    queued += edits.syncCourseOverride(moodleCourseId: identity, colorHex: String(format: "#%06X", hex), for: signIn)
                }
            }
            if conflict.categories.contains(.courseNames) {
                let customNames = CourseStore.shared.loadCourseCustomNames()
                for (courseNo, locales) in customNames {
                    guard let moodleId = moodleIdByCourseNo[courseNo] else { continue }
                    for (locale, name) in locales where !name.isEmpty {
                        queued += edits.syncCourseOverride(moodleCourseId: moodleId, customName: name, locale: locale, for: signIn)
                    }
                }
            }
        }
        if conflict.categories.contains(.assignments) {
            let archived = AssignmentStore.shared.loadArchivedAssignmentIds()
            let completed = AssignmentStore.shared.loadLocallyCompletedAssignmentIds()
            for id in archived {
                queued.append(edits.syncAssignmentOverride(moodleId: id, status: "archived", for: signIn))
            }
            for id in completed {
                queued.append(edits.syncAssignmentOverride(moodleId: id, status: "locally_completed", for: signIn))
            }
            let cleared = AssignmentMarksReconciler.assignmentMarksToClear(
                server: conflict.serverMarkedAssignments, local: archived.union(completed)
            )
            for id in cleared {
                queued.append(edits.syncAssignmentOverride(moodleId: id, status: "none", for: signIn))
            }
            if let serverIgnoredCourses = conflict.serverIgnoredCourses {
                let ignoredCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
                queued += edits.syncCourseIgnores(ignoredCourses, for: signIn)
                for course in CourseIgnoresReconciler.courseIgnoresToClear(server: serverIgnoredCourses, local: ignoredCourses) {
                    queued.append(edits.syncCourseIgnore(
                        semester: course.semester, courseNo: course.courseNo,
                        moodleIdNumber: course.moodleId, ignore: false, for: signIn
                    ))
                }
            }
        }
        return queued.compactMap { $0 }
    }

    static func dropLocalCopies(
        for conflict: Conflict, courses: CourseStore, assignments: AssignmentStore, colors: CourseColorStore,
        signIn: SignIn
    ) {
        if conflict.categories.contains(.courseColors) {
            colors.forgetColors(for: signIn)
        }
        if conflict.categories.contains(.courseNames) {
            courses.saveCourseCustomNames([:], for: signIn)
        }
        if conflict.categories.contains(.assignments) {
            assignments.replaceArchivedAssignmentIds([], for: signIn)
            assignments.replaceLocallyCompletedAssignmentIds([], for: signIn)
            if conflict.serverIgnoredCourses != nil {
                assignments.replaceIgnoredAssignmentCourses([], for: signIn)
            }
        }
    }

    static func keepLocalCourses(
        _ terms: [(semester: String, courses: [SDCourse])],
        hiding deletedNos: Set<String>,
        on backend: some CourseSyncBackend,
        for signIn: SignIn
    ) async throws {
        try await BackendClient.$holdsResend.withValue({ !SyncPolicy.current.uploadsCourses }) {
            for (semester, courses) in terms {
                let hiddenNos = CourseTombstone.courseNos(hiddenIn: semester, in: deletedNos)
                let stubs = hiddenNos.subtracting(courses.map(\.courseNo)).sorted()
                    .map { SDCourse(courseNo: $0, courseName: $0) }
                guard !courses.isEmpty || !stubs.isEmpty else { continue }
                if !courses.isEmpty {
                    try await backend.deleteAllCourses(semester: semester, madeAt: Date(), for: signIn)
                }
                try await backend.uploadCourses(
                    SchoolDataUploader.courseUploadRequest(courses + stubs, semester: semester), addedAt: nil, for: signIn
                )
                for courseNo in hiddenNos.sorted() {
                    try await backend.deleteCourse(
                        courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo), madeAt: Date(), for: signIn
                    )
                }
            }
        }
    }
}
