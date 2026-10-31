import Defaults
import Foundation
import os

/// Sends the user's own edits of marks, course ignores, colours, names and hides to the outbox at
/// once; they never wait for a pull.
@MainActor
final class EditSender {
    private let coordinator: CloudSyncCoordinator
    private let push: PushCoordinator
    private let poller: RevisionPoller
    private let localEdits: LocalEdits

    init(coordinator: CloudSyncCoordinator, push: PushCoordinator, poller: RevisionPoller, localEdits: LocalEdits) {
        self.coordinator = coordinator
        self.push = push
        self.poller = poller
        self.localEdits = localEdits
    }

    @discardableResult
    func syncAssignmentOverride(moodleId: String, status: String) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled], Defaults[.syncAssignments] else { return nil }
        AppLogger.sync.debug("override enqueue: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        guard let moodleAssignmentId = Int(moodleId) else { return nil }
        localEdits.overrideEditGeneration &+= 1
        localEdits.pendingOverrides.insert(moodleId)
        let queued = Task { [weak self] in
            guard let self else { return }
            await coordinator.enqueueAssignmentOverride(
                moodleCourseId: 0,
                moodleAssignmentId: moodleAssignmentId,
                localStatus: status)
            localEdits.pendingOverrides.remove(moodleId)
        }
        coordinator.scheduleTick(after: 1)
        poller.noteActivity()
        return queued
    }

    @discardableResult
    func syncCourseIgnore(semester: String, courseNo: String, moodleIdNumber: String?, ignore: Bool) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled] else { return nil }
        let moodleId = moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
        let moodleCourseId = MoodleFiles.shared.lookupMoodleCourseId(idnumber: moodleId)
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        localEdits.overrideEditGeneration &+= 1
        localEdits.pendingOverrides.insert(key)
        let queued = Task { [weak self] in
            guard let self else { return }
            await coordinator.enqueueCourseIgnore(
                semester: semester, courseNo: courseNo, moodleId: moodleId,
                moodleCourseId: moodleCourseId, ignore: ignore)
            localEdits.pendingOverrides.remove(key)
        }
        coordinator.scheduleTick(after: 1)
        poller.noteActivity()
        return queued
    }

    @discardableResult
    func syncCourseIgnores(_ keys: Set<String>) -> [Task<Void, Never>?] {
        keys.sorted().map { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return nil }
            let course = (CourseStore.shared.loadCourses(semester: semester)
                + CourseStore.shared.loadUserAddedCourses(semester: semester)).first { $0.courseNo == courseNo }
            return syncCourseIgnore(semester: semester, courseNo: courseNo, moodleIdNumber: course?.moodleIdNumber, ignore: true)
        }
    }

    @discardableResult
    func syncCourseOverride(
        moodleCourseId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil
    ) -> [Task<Void, Never>?] {
        guard Defaults[.cloudSyncEnabled] else { return [] }
        let semester = CourseSelectionService.currentSemesterCode()
        let queued = [
            colorHex.flatMap {
                coordinator.enqueueCourseColorOverride(moodleId: moodleCourseId, semester: semester, colorHex: $0)
            },
            customName.flatMap {
                coordinator.enqueueCourseNameOverride(
                    moodleId: moodleCourseId, semester: semester, customName: $0, locale: locale)
            },
        ]
        coordinator.scheduleTick(after: 1)
        poller.noteActivity()
        return queued
    }

    /// Courses added by hand, by server key: each goes to the outbox with its stamp, and a hide of
    /// it queued before the add is dropped.
    func addCourses(_ keys: [String], semester: String) {
        let addedAt = Date()
        Task { await coordinator.discardCourseDeletes(courseKeys: Set(keys), madeBefore: addedAt) }
        guard SyncPolicy.current.uploadsCourses else { return }
        let prefix = CourseTombstone.serverKey(semester: semester, courseNo: "")
        for key in keys where key.hasPrefix(prefix) {
            coordinator.addCourse(semester: semester, courseNo: String(key.dropFirst(prefix.count)))
        }
    }

    func deleteBackendCourse(courseNo: String, semester: String) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let hiddenAt = Date()
        localEdits.recentCourseDeletions[courseNo] = hiddenAt
        poller.noteActivity()
        Task { await coordinator.deleteCourse(semester: semester, courseNo: courseNo, at: hiddenAt) }
    }

    @discardableResult
    func deleteBackendCourses(
        semester: String? = nil,
        thenLocally resetLocally: @MainActor () -> Void = {}
    ) async -> Bool {
        guard Defaults[.cloudSyncEnabled] else {
            resetLocally()
            return true
        }
        if let semester { localEdits.resettingSemesters.insert(semester) }
        defer { if let semester { localEdits.resettingSemesters.remove(semester) } }
        let madeAt = Date()
        do {
            try await Self.resetCourses(semester: semester, on: coordinator, onServer: { [push] in
                try await push.deleteAllCourses(semester: semester, madeAt: madeAt)
                AppLogger.sync.info("deleteBackendCourses ok: \(semester ?? "all", privacy: .public)")
                if let semester { CourseStore.shared.recordSemesterReset(semester) }
                push.forgetUploads(semester: semester)
            }, thenLocally: resetLocally)
            return true
        } catch {
            AppLogger.sync.error("deleteBackendCourses failed: \(error, privacy: .private)")
            return false
        }
    }

    /// Resets the courses on the server, then clears them here and drops the deletes queued until
    /// that moment, so a hide made during the request is gone from both and a later one kept in both.
    static func resetCourses(
        semester: String?, on coordinator: CloudSyncCoordinator,
        onServer reset: () async throws -> Void, thenLocally resetLocally: () -> Void
    ) async throws {
        try await reset()
        let resetAt = Date()
        resetLocally()
        await coordinator.discardCourseIgnores(semester: semester)
        await coordinator.discardCourseDeletes(semester: semester, madeBefore: resetAt)
    }

    nonisolated static func courseColorsAfterCoursesChange(coursesNowOn: Bool) -> Bool {
        coursesNowOn
    }

    func reassignAllCourseColors() {
        let semester = CourseSelectionService.currentSemesterCode()
        let courses = CanonicalCourseProvider().currentCourses(semester: semester)
        TigerDuckTheme.reassignAll(courseNos: courses.map(\.courseNo))
        guard Defaults[.cloudSyncEnabled] else { return }
        let colorMap = TigerDuckTheme.snapshot()
        for course in courses {
            guard let hex = colorMap[course.courseNo] else { continue }
            syncCourseOverride(
                moodleCourseId: Self.colorIdentity(of: course, semester: semester),
                colorHex: String(format: "#%06X", hex)
            )
        }
    }

    func syncColorPick(_ hex: UInt32, for picked: SDCourse, changed: [String: UInt32]) {
        guard Defaults[.cloudSyncEnabled] else { return }
        var colors = changed
        colors[picked.courseNo] = hex & 0xFFFFFF
        let others = colors.count > 1
        let identities = Self.courseIdentities(
            picked: picked,
            termCourses: others
                ? SemesterCatalog.availableSemesters().map { ($0, CourseStore.shared.loadCourses(semester: $0)) } : [],
            userAdded: others ? CourseStore.shared.loadUserAddedCourses() : []
        )
        for override in Self.courseColorOverrides(colors, moodleIds: identities) {
            syncCourseOverride(moodleCourseId: override.moodleId, colorHex: override.colorHex)
        }
    }

    /// How a colour edit names each course, preferring a row with a Moodle id where one course
    /// number has several.
    static func courseIdentities(
        picked: SDCourse,
        termCourses: [(semester: String, courses: [SDCourse])],
        userAdded: [SDCourse]
    ) -> [String: String] {
        let named = [(picked.semester, picked)]
            + termCourses.flatMap { term in term.courses.map { (term.semester, $0) } }
            + userAdded.map { ($0.semester, $0) }
        var ids: [String: String] = [:]
        for (semester, course) in named where ids[course.courseNo] == nil && course.moodleIdNumber?.isEmpty == false {
            ids[course.courseNo] = colorIdentity(of: course, semester: semester)
        }
        for (semester, course) in named where ids[course.courseNo] == nil {
            ids[course.courseNo] = colorIdentity(of: course, semester: semester)
        }
        return ids
    }

    /// The Moodle id number, or the term and the number of a course without one; an empty term is
    /// read as the current one.
    static func colorIdentity(of course: SDCourse, semester: String) -> String {
        OutboxSender.identity(
            semester: semester.isEmpty ? CourseSelectionService.currentSemesterCode() : semester,
            courseNo: course.courseNo, moodleIdNumber: course.moodleIdNumber
        )
    }

    nonisolated static func courseColorOverrides(
        _ colors: [String: UInt32],
        moodleIds: [String: String]
    ) -> [(moodleId: String, colorHex: String)] {
        colors.keys.sorted().compactMap { courseNo in
            guard let moodleId = moodleIds[courseNo], let hex = colors[courseNo] else { return nil }
            return (moodleId, String(format: "#%06X", hex))
        }
    }
}
