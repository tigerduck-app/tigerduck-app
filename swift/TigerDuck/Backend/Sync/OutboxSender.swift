import Defaults
import Foundation

nonisolated struct CourseKeyUnknownError: Error {}

nonisolated struct CourseIgnoreNotStoredError: Error {}

@MainActor
final class OutboxSender {
    private let push: PushCoordinator
    private let addedCourseUpload: @MainActor (_ semester: String, _ courseNo: String) -> PushAPI.CourseUploadRequest?
    private let uploadsCourses: @MainActor () -> Bool
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private let account: AccountSession
    private let courses: CourseStore
    let kept: KeptValues
    var onCourseAddLanded: @MainActor (_ key: String) -> Void = { _ in }

    init(
        push: PushCoordinator,
        addedCourseUpload: @escaping @MainActor (_ semester: String, _ courseNo: String) -> PushAPI.CourseUploadRequest?,
        uploadsCourses: @escaping @MainActor () -> Bool,
        isProtectedDataAvailable: @escaping @MainActor () -> Bool,
        account: AccountSession,
        courses: CourseStore = .shared,
        kept: KeptValues? = nil
    ) {
        self.push = push
        self.addedCourseUpload = addedCourseUpload
        self.uploadsCourses = uploadsCourses
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.account = account
        self.courses = courses
        self.kept = kept ?? KeptValues()
    }

    func send(_ op: SyncOp, newerQueued: @MainActor (SyncOp) async -> Bool) async throws {
        let isCurrent = account.currentCheck()
        func applies() async -> Bool { !(await newerQueued(op)) && isCurrent() && !Task.isCancelled }
        switch op {
        case .courseOverride(let semester, let moodleId, let customName, let colorHex, let locale, let stamp):
            guard let (courseKey, courseNo) = courseKey(semester: semester, identity: moodleId) else {
                throw CourseKeyUnknownError()
            }
            let resolvedLocale = customName != nil ? (locale ?? Locale.current.language.languageCode?.identifier) : nil
            let reply = try await push.patchCourseOverride(
                courseKey: courseKey, colorHex: colorHex, customName: customName, locale: resolvedLocale, madeAt: stamp
            )
            guard await applies() else { return }
            if colorHex != nil, !reply.applied.contains("color_hex") {
                kept.colorKept(reply.colorHex, courseNo: courseNo)
            }
            if customName != nil, let resolvedLocale, !reply.applied.contains("custom_name") {
                kept.nameKept(reply.customNames[resolvedLocale], courseNo: courseNo, locale: resolvedLocale)
            }

        case .assignmentOverride(_, let moodleAssignmentId, let localStatus, let stamp):
            let reply = try await push.patchAssignmentOverride(
                moodleAssignmentId: String(moodleAssignmentId), localStatus: localStatus, madeAt: stamp
            )
            if !reply.applied, await applies() {
                kept.markKept(reply.localStatus, assignmentId: String(moodleAssignmentId))
            }

        case .courseIgnore(let semester, let courseNo, _, let moodleCourseId, let ignore, let stamp):
            let reply = try await push.patchCourseOverride(
                courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo),
                ignoreAssignments: ignore, moodleCourseId: moodleCourseId, madeAt: stamp
            )
            guard let ignoring = reply.ignoreAssignments else { throw CourseIgnoreNotStoredError() }
            if ignore != nil, !reply.applied.contains("ignore_assignments"), await applies() {
                kept.ignoreKept(ignoring, key: CourseTombstone.key(semester: semester, courseNo: courseNo))
            }

        case .courseDelete(let semester, let courseNo, let stamp):
            try await push.deleteCourse(
                courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo), madeAt: stamp
            )

        case .courseAdd(let semester, let courseNo, let stamp):
            guard isProtectedDataAvailable() else { throw CancellationError() }
            let isCurrent = account.currentCheck()
            guard var request = addedCourseUpload(semester, courseNo) else { return }
            let key = CourseTombstone.serverKey(semester: semester, courseNo: courseNo)
            request.adds = [PushAPI.CourseAdd(courseKey: key, hlc: PushAPI.clock(of: stamp))]
            guard try await push.uploadCoursesIfChanged(
                request, semester: semester, addedAt: stamp,
                isCurrent: { [uploadsCourses] in uploadsCourses() && isCurrent() }
            ) else { return }
            onCourseAddLanded(CourseTombstone.key(semester: semester, courseNo: courseNo))
        }
    }

    func courseKey(semester: String, identity: String) -> (key: String, courseNo: String)? {
        let terms = [semester] + SemesterCatalog.availableSemesters().filter { $0 != semester }
        for term in terms {
            let held = courses.loadCourses(semester: term) + courses.loadUserAddedCourses(semester: term)
            if let course = held.first(where: { Self.identity(of: $0, semester: term) == identity }) {
                return (CourseTombstone.serverKey(semester: term, courseNo: course.courseNo), course.courseNo)
            }
        }
        guard let term = terms.first(where: { identity.hasPrefix($0) && identity.count > $0.count }) else { return nil }
        let courseNo = String(identity.dropFirst(term.count))
        return (CourseTombstone.serverKey(semester: term, courseNo: courseNo), courseNo)
    }

    nonisolated static func identity(semester: String, courseNo: String, moodleIdNumber: String?) -> String {
        moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
    }

    static func identity(of course: SDCourse, semester: String) -> String {
        identity(semester: semester, courseNo: course.courseNo, moodleIdNumber: course.moodleIdNumber)
    }
}

@MainActor
struct KeptValues {
    var policy: @MainActor () -> SyncPolicy = { .current }
    var colors: CourseColorStore = .shared
    var courses: CourseStore = .shared
    var assignments: AssignmentStore = .shared

    func colorKept(_ hex: String?, courseNo: String) {
        let policy = policy()
        guard policy.switchedOn.contains("course_colors"), policy.sendsCourseOverride("course_colors"),
              let hex, let value = UInt32(hex.dropFirst(), radix: 16) else { return }
        colors.applyColors([(courseNo, value)], palette: TigerDuckTheme.coursePaletteHexes)
    }

    func nameKept(_ name: String?, courseNo: String, locale: String) {
        let policy = policy()
        guard policy.switchedOn.contains("course_names"), policy.sendsCourseOverride("course_names") else { return }
        let names = courses.loadCourseCustomNames()
        var updated = names
        var forCourse = updated[courseNo] ?? [:]
        if let name, !name.isEmpty { forCourse[locale] = name } else { forCourse.removeValue(forKey: locale) }
        updated[courseNo] = forCourse.isEmpty ? nil : forCourse
        if updated != names { courses.saveCourseCustomNames(updated) }
    }

    func markKept(_ status: String, assignmentId: String) {
        guard policy().sendsAssignmentMarks else { return }
        var archived = assignments.loadArchivedAssignmentIds()
        var completed = assignments.loadLocallyCompletedAssignmentIds()
        archived.remove(assignmentId)
        completed.remove(assignmentId)
        switch status {
        case "archived", "ignored": archived.insert(assignmentId)
        case "locally_completed": completed.insert(assignmentId)
        default: break
        }
        if archived != assignments.loadArchivedAssignmentIds() { assignments.replaceArchivedAssignmentIds(archived) }
        if completed != assignments.loadLocallyCompletedAssignmentIds() {
            assignments.replaceLocallyCompletedAssignmentIds(completed)
        }
    }

    func ignoreKept(_ ignoring: Bool, key: String) {
        guard policy().sendsCourseIgnores else { return }
        var ignored = assignments.loadIgnoredAssignmentCourses()
        if ignoring { ignored.insert(key) } else { ignored.remove(key) }
        if ignored != assignments.loadIgnoredAssignmentCourses() { assignments.replaceIgnoredAssignmentCourses(ignored) }
    }
}
