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
        localEdits: LocalEdits, push: PushCoordinator, clock: SyncClock, for signIn: SignIn
    ) async throws {
        guard SyncPolicy.current.uploadsCourses else { return }
        let terms = SemesterCatalog.availableSemesters().map { semester in
            (semester: semester, fetched: CourseStore.shared.loadCourses(semester: semester),
             userAdded: CourseStore.shared.loadUserAddedCourses(semester: semester))
        }
        let latched = Set(terms.map(\.semester))
        localEdits.resettingSemesters.formUnion(latched)
        defer {
            localEdits.resettingSemesters.subtract(latched)
            let landedAt = clock.mark()
            for semester in latched { CourseStore.shared.recordSemesterReset(semester, at: landedAt, for: signIn) }
        }
        try await keepLocalCourses(
            terms, hiding: Set(CourseStore.shared.loadDeletedCourseNos()), on: push, for: signIn, clock: clock
        )
    }

    static func queueLocalEdits(of conflict: Conflict, edits: EditSender, for signIn: SignIn) -> [Task<Void, Never>] {
        var queued: [Task<Void, Never>?] = []
        let resent = courseOverridesToResend(
            for: Set(conflict.categories), syncsNames: SyncPolicy.current.switchedOn.contains(.courseNames),
            terms: SemesterCatalog.availableSemesters(), courses: .shared, colors: TigerDuckTheme.courseColorMap
        )
        for color in resent.colors {
            queued += edits.syncCourseOverride(moodleCourseId: color.identity, colorHex: color.colorHex, for: signIn)
        }
        for name in resent.names {
            queued += edits.syncCourseOverride(moodleCourseId: name.identity, customName: name.name, locale: name.locale, for: signIn)
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

    static func courseOverridesToResend(
        for categories: Set<SyncCategory>, syncsNames: Bool, terms: [String], courses: CourseStore, colors colorMap: [String: UInt32]
    ) -> (colors: [(identity: String, colorHex: String)], names: [(identity: String, name: String, locale: String)]) {
        let colors = categories.contains(.courseColors)
        // The term resets of Use Local for courses clear the backend's names as well.
        let names = categories.contains(.courseNames) || (categories.contains(.courses) && syncsNames)
        guard colors || names else { return ([], []) }
        let identities = EditSender.courseIdentities(terms.flatMap { term in
            (courses.loadCourses(semester: term) + courses.loadUserAddedCourses(semester: term)).map { (semester: term, course: $0) }
        })
        let resentColors = !colors ? [] : colorMap.compactMap { courseNo, hex in
            identities[courseNo].map { (identity: $0, colorHex: String(format: "#%06X", hex)) }
        }
        let resentNames = !names ? [] : courses.loadCourseCustomNames().flatMap { courseNo, locales in
            identities[courseNo].map { identity in
                locales.filter { !$0.value.isEmpty }.map { (identity: identity, name: $0.value, locale: $0.key) }
            } ?? []
        }
        return (resentColors, resentNames)
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

    /// The backend's term reset clears every add stamped at or before it, and the backend takes a
    /// course an upload lists outside `adds` for the school's.
    static func keepLocalCourses(
        _ terms: [(semester: String, fetched: [SDCourse], userAdded: [SDCourse])],
        hiding deletedNos: Set<String>,
        on backend: some CourseSyncBackend,
        for signIn: SignIn,
        clock: SyncClock
    ) async throws {
        try await BackendClient.$holdsResend.withValue({ !SyncPolicy.current.uploadsCourses }) {
            for (semester, fetched, userAdded) in terms {
                let courses = fetched + userAdded
                let hiddenNos = CourseTombstone.courseNos(hiddenIn: semester, in: deletedNos)
                let stubs = hiddenNos.subtracting(courses.map(\.courseNo)).sorted()
                    .map { SDCourse(courseNo: $0, courseName: $0) }
                guard !courses.isEmpty || !stubs.isEmpty else { continue }
                let resetAt = clock.stamp()
                if !courses.isEmpty {
                    try await backend.deleteAllCourses(semester: semester, madeAt: resetAt, for: signIn)
                }
                let addedAt = clock.stamp()
                let adds = Set(userAdded.filter { $0.userAddedOrigin == .addedHere }.map(\.courseNo))
                    .subtracting(fetched.map(\.courseNo)).subtracting(hiddenNos).sorted()
                var request = SchoolDataUploader.courseUploadRequest(courses + stubs, semester: semester)
                if !adds.isEmpty {
                    request.handAddedCourses = adds.map {
                        PushAPI.CourseAdd(
                            courseKey: CourseTombstone.serverKey(semester: semester, courseNo: $0), hlc: PushAPI.clock(of: addedAt)
                        )
                    }
                }
                try await backend.uploadCourses(request, addedAt: adds.isEmpty ? nil : addedAt, for: signIn)
                for courseNo in hiddenNos.sorted() {
                    try await backend.deleteCourse(
                        courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo),
                        kind: fetched.contains { $0.courseNo == courseNo } ? .hide : nil, madeAt: clock.stamp(), for: signIn
                    )
                }
            }
        }
    }
}
