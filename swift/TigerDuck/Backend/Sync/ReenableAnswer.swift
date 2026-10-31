import Foundation
import os

/// Carries out the user's answer to the re-enable alert: Keep Local sends this device's copies,
/// Use Server drops them and pulls the server's.
@MainActor
enum ReenableAnswer {
    typealias Conflict = SyncConflicts.ReenableConflict

    struct Effects {
        let isCurrent: () -> Bool
        let take: (_ categories: [String], _ keepLocal: Bool) -> Set<String>
        let release: (_ held: Set<String>) -> Void
        let end: (_ held: Set<String>) -> Void
        let dropQueuedEdits: (_ categories: Set<String>, _ courseIgnores: Bool) async -> Void
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
        guard effects.isCurrent() else { return }
        let held = effects.take(conflict.categories, keepLocal)
        var coursesSaveFailed = false
        if keepLocal {
            defer { effects.end(held) }
            if conflict.categories.contains("courses") {
                do {
                    try await effects.sendCourses()
                } catch {
                    AppLogger.sync.error("[reenable] keep-local course sync failed (server may be empty): \(error, privacy: .private)")
                    if effects.isCurrent() { effects.markCoursesForCheck() }
                    coursesSaveFailed = true
                }
            }
            guard effects.isCurrent() else { return }
            for task in effects.queueEdits() { await task.value }
            guard effects.isCurrent() else { return }
            effects.release(held)
        } else {
            effects.dropLocalCopies()
            await effects.syncFromServer(true)
        }
        guard effects.isCurrent() else { return }
        effects.noteAnswered(coursesSaveFailed)
    }

    static func sendLocalCourses(
        localEdits: LocalEdits, push: PushCoordinator, isCurrent: () -> Bool
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
            for semester in latched { CourseStore.shared.recordSemesterReset(semester) }
        }
        try await keepLocalCourses(
            terms, hiding: Set(CourseStore.shared.loadDeletedCourseNos()), on: push, isCurrent: isCurrent
        )
    }

    static func queueLocalEdits(of conflict: Conflict, edits: EditSender) -> [Task<Void, Never>] {
        var queued: [Task<Void, Never>?] = []
        if conflict.categories.contains("course_colors") || conflict.categories.contains("course_names") {
            let terms = SemesterCatalog.availableSemesters().map { ($0, CourseStore.shared.loadCourses(semester: $0)) }
            let moodleIdByCourseNo = Dictionary(
                terms.flatMap(\.1).compactMap { c in c.moodleIdNumber.map { (c.courseNo, $0) } },
                uniquingKeysWith: { first, _ in first })
            if conflict.categories.contains("course_colors") {
                let identities = terms.flatMap { term in
                    term.1.map { ($0.courseNo, EditSender.colorIdentity(of: $0, semester: term.0)) }
                }
                let identityByCourseNo = moodleIdByCourseNo.merging(identities, uniquingKeysWith: { first, _ in first })
                let colorMap = TigerDuckTheme.courseColorMap
                for (courseNo, hex) in colorMap {
                    guard let identity = identityByCourseNo[courseNo] else { continue }
                    queued += edits.syncCourseOverride(moodleCourseId: identity, colorHex: String(format: "#%06X", hex))
                }
            }
            if conflict.categories.contains("course_names") {
                let customNames = CourseStore.shared.loadCourseCustomNames()
                for (courseNo, locales) in customNames {
                    guard let moodleId = moodleIdByCourseNo[courseNo] else { continue }
                    for (locale, name) in locales where !name.isEmpty {
                        queued += edits.syncCourseOverride(moodleCourseId: moodleId, customName: name, locale: locale)
                    }
                }
            }
        }
        if conflict.categories.contains("assignments") {
            let archived = AssignmentStore.shared.loadArchivedAssignmentIds()
            let completed = AssignmentStore.shared.loadLocallyCompletedAssignmentIds()
            for id in archived {
                queued.append(edits.syncAssignmentOverride(moodleId: id, status: "archived"))
            }
            for id in completed {
                queued.append(edits.syncAssignmentOverride(moodleId: id, status: "locally_completed"))
            }
            let cleared = AssignmentMarksReconciler.assignmentMarksToClear(
                server: conflict.serverMarkedAssignments, local: archived.union(completed)
            )
            for id in cleared {
                queued.append(edits.syncAssignmentOverride(moodleId: id, status: "none"))
            }
            if let serverIgnoredCourses = conflict.serverIgnoredCourses {
                let ignoredCourses = AssignmentStore.shared.loadIgnoredAssignmentCourses()
                queued += edits.syncCourseIgnores(ignoredCourses)
                for course in CourseIgnoresReconciler.courseIgnoresToClear(server: serverIgnoredCourses, local: ignoredCourses) {
                    queued.append(edits.syncCourseIgnore(
                        semester: course.semester, courseNo: course.courseNo,
                        moodleIdNumber: course.moodleId, ignore: false
                    ))
                }
            }
        }
        return queued.compactMap { $0 }
    }

    static func dropLocalCopies(
        for conflict: Conflict, courses: CourseStore, assignments: AssignmentStore, colors: CourseColorFiles
    ) {
        if conflict.categories.contains("course_colors") {
            colors.saveCourseColorMap([:])
            TigerDuckTheme.reload()
        }
        if conflict.categories.contains("course_names") {
            courses.saveCourseCustomNames([:])
        }
        if conflict.categories.contains("assignments") {
            assignments.replaceArchivedAssignmentIds([])
            assignments.replaceLocallyCompletedAssignmentIds([])
            if conflict.serverIgnoredCourses != nil {
                assignments.replaceIgnoredAssignmentCourses([])
            }
        }
    }

    static func keepLocalCourses(
        _ terms: [(semester: String, courses: [SDCourse])],
        hiding deletedNos: Set<String>,
        on backend: some CourseSyncBackend,
        isCurrent: () -> Bool
    ) async throws {
        for (semester, courses) in terms {
            let hiddenNos = CourseTombstone.courseNos(hiddenIn: semester, in: deletedNos)
            let stubs = hiddenNos.subtracting(courses.map(\.courseNo)).sorted()
                .map { SDCourse(courseNo: $0, courseName: $0) }
            guard !courses.isEmpty || !stubs.isEmpty else { continue }
            if !courses.isEmpty {
                guard isCurrent() else { throw CancellationError() }
                try await backend.deleteAllCourses(semester: semester, madeAt: Date())
            }
            guard isCurrent() else { throw CancellationError() }
            try await backend.uploadCourses(SchoolDataUploader.courseUploadRequest(courses + stubs, semester: semester), addedAt: nil)
            for courseNo in hiddenNos.sorted() {
                guard isCurrent() else { throw CancellationError() }
                try await backend.deleteCourse(
                    courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo), madeAt: Date()
                )
            }
        }
    }
}
