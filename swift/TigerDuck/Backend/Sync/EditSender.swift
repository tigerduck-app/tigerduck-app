import Defaults
import Foundation
import os

@MainActor
final class EditSender {
    private let coordinator: CloudSyncCoordinator
    private let push: PushCoordinator
    private let poller: RevisionPoller
    private let localEdits: LocalEdits
    private let account: AccountSession

    init(
        coordinator: CloudSyncCoordinator, push: PushCoordinator, poller: RevisionPoller, localEdits: LocalEdits,
        account: AccountSession
    ) {
        self.coordinator = coordinator
        self.push = push
        self.poller = poller
        self.localEdits = localEdits
        self.account = account
    }

    @discardableResult
    func syncAssignmentOverride(moodleId: String, status: String, for signIn: SignIn) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled], Defaults[.syncAssignments] else { return nil }
        AppLogger.sync.debug("override enqueue: \(moodleId, privacy: .private) → \(status, privacy: .public)")
        guard let moodleAssignmentId = Int(moodleId) else { return nil }
        localEdits.overrideEditGeneration &+= 1
        let queued = coordinator.enqueueAssignmentOverride(
            moodleCourseId: 0, moodleAssignmentId: moodleAssignmentId, localStatus: status, for: signIn
        )
        coordinator.scheduleTick(after: 1)
        poller.noteActivity()
        return queued
    }

    @discardableResult
    func syncCourseIgnore(
        semester: String, courseNo: String, moodleIdNumber: String?, ignore: Bool, for signIn: SignIn
    ) -> Task<Void, Never>? {
        guard Defaults[.cloudSyncEnabled] else { return nil }
        let moodleId = moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
        let moodleCourseId = CourseLookup.moodleCourseId(idnumber: moodleId)
        localEdits.overrideEditGeneration &+= 1
        let queued = coordinator.enqueueCourseIgnore(
            semester: semester, courseNo: courseNo, moodleId: moodleId,
            moodleCourseId: moodleCourseId, ignore: ignore, for: signIn)
        coordinator.scheduleTick(after: 1)
        poller.noteActivity()
        return queued
    }

    @discardableResult
    func syncCourseIgnores(_ keys: Set<String>, for signIn: SignIn) -> [Task<Void, Never>?] {
        keys.sorted().map { key in
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { return nil }
            let course = (CourseStore.shared.loadCourses(semester: semester)
                + CourseStore.shared.loadUserAddedCourses(semester: semester)).first { $0.courseNo == courseNo }
            return syncCourseIgnore(
                semester: semester, courseNo: courseNo, moodleIdNumber: course?.moodleIdNumber, ignore: true, for: signIn
            )
        }
    }

    @discardableResult
    func syncCourseOverride(
        moodleCourseId: String,
        colorHex: String? = nil,
        customName: String? = nil,
        locale: String? = nil,
        for signIn: SignIn
    ) -> [Task<Void, Never>?] {
        guard Defaults[.cloudSyncEnabled] else { return [] }
        let semester = CourseSelectionService.currentSemesterCode()
        let queued = [
            colorHex.flatMap {
                coordinator.enqueueCourseColorOverride(moodleId: moodleCourseId, semester: semester, colorHex: $0, for: signIn)
            },
            customName.flatMap {
                coordinator.enqueueCourseNameOverride(
                    moodleId: moodleCourseId, semester: semester, customName: $0, locale: locale, for: signIn)
            },
        ]
        coordinator.scheduleTick(after: 1)
        poller.noteActivity()
        return queued
    }

    func addCourses(_ serverKeys: [String], semester: String, for signIn: SignIn) {
        let addedAt = Date()
        Task { await coordinator.discardCourseDeletes(courseKeys: Set(serverKeys), madeBeforeAction: addedAt) }
        guard SyncPolicy.current.uploadsCourses else { return }
        let prefix = CourseTombstone.serverKey(semester: semester, courseNo: "")
        for key in serverKeys where key.hasPrefix(prefix) {
            coordinator.addCourse(semester: semester, courseNo: String(key.dropFirst(prefix.count)), for: signIn)
        }
    }

    func deleteBackendCourse(courseNo: String, semester: String, for signIn: SignIn) {
        guard Defaults[.cloudSyncEnabled] else { return }
        let hiddenAt = Date()
        localEdits.setRecentCourseDeletions(localEdits.recentCourseDeletions.merging([courseNo: hiddenAt]) { $1 }, for: signIn)
        poller.noteActivity()
        Task { await coordinator.deleteCourse(semester: semester, courseNo: courseNo, at: hiddenAt, for: signIn) }
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
        let signIn = await account.startingSignIn
        if let semester { localEdits.resettingSemesters.insert(semester) }
        defer { if let semester { localEdits.resettingSemesters.remove(semester) } }
        let madeAt = Date()
        do {
            try await Self.resetCourses(semester: semester, on: coordinator, onServer: { [push] in
                try await push.deleteAllCourses(semester: semester, madeAt: madeAt, for: signIn)
                AppLogger.sync.info("deleteBackendCourses ok: \(semester ?? "all", privacy: .public)")
                if let semester { CourseStore.shared.recordSemesterReset(semester, for: signIn) }
                push.forgetUploads(semester: semester)
            }, thenLocally: resetLocally)
            return true
        } catch {
            AppLogger.sync.error("deleteBackendCourses failed: \(error, privacy: .private)")
            return false
        }
    }

    static func resetCourses(
        semester: String?, on coordinator: CloudSyncCoordinator,
        onServer reset: () async throws -> Void, thenLocally resetLocally: () -> Void
    ) async throws {
        try await reset()
        let serverResetLandedAt = Date()
        resetLocally()
        await coordinator.discardCourseIgnores(semester: semester)
        await coordinator.discardCourseDeletes(semester: semester, madeBeforeAction: serverResetLandedAt)
    }

    nonisolated static func courseColorsAfterCoursesChange(coursesNowOn: Bool) -> Bool {
        coursesNowOn
    }

    func syncsCourseColors(coursesNowOn: Bool) -> Bool {
        Self.courseColorsAfterCoursesChange(coursesNowOn: coursesNowOn)
    }

    func reassignAllCourseColors(for signIn: SignIn) {
        let semester = CourseSelectionService.currentSemesterCode()
        let courses = CanonicalCourseProvider().currentCourses(semester: semester)
        TigerDuckTheme.reassignAll(courses: courses, for: signIn)
        guard Defaults[.cloudSyncEnabled] else { return }
        for override in Self.resetColorOverrides(courses, colors: TigerDuckTheme.snapshot(), semester: semester) {
            syncCourseOverride(moodleCourseId: override.moodleId, colorHex: override.colorHex, for: signIn)
        }
    }

    /// Every course goes, its colour changed or not, so the other devices take the reset too.
    static func resetColorOverrides(
        _ courses: [SDCourse], colors: [String: UInt32], semester: String
    ) -> [(moodleId: String, colorHex: String)] {
        let ids = Dictionary(
            courses.map { ($0.courseNo, colorIdentity(of: $0, semester: semester)) }, uniquingKeysWith: { first, _ in first }
        )
        return courseColorOverrides(colors.filter { ids[$0.key] != nil }, moodleIds: ids)
    }

    func syncColorPick(_ hex: UInt32, for picked: SDCourse, changed: [String: UInt32], signIn: SignIn) {
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
            syncCourseOverride(moodleCourseId: override.moodleId, colorHex: override.colorHex, for: signIn)
        }
    }

    static func courseIdentities(
        picked: SDCourse,
        termCourses: [(semester: String, courses: [SDCourse])],
        userAdded: [SDCourse]
    ) -> [String: String] {
        courseIdentities([(semester: picked.semester, course: picked)]
            + termCourses.flatMap { term in term.courses.map { (semester: term.semester, course: $0) } }
            + userAdded.map { (semester: $0.semester, course: $0) })
    }

    static func courseIdentities(_ named: [(semester: String, course: SDCourse)]) -> [String: String] {
        var ids: [String: String] = [:]
        for (semester, course) in named where ids[course.courseNo] == nil && course.moodleIdNumber?.isEmpty == false {
            ids[course.courseNo] = colorIdentity(of: course, semester: semester)
        }
        for (semester, course) in named where ids[course.courseNo] == nil {
            ids[course.courseNo] = colorIdentity(of: course, semester: semester)
        }
        return ids
    }

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
