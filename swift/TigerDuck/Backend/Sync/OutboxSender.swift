import Defaults
import Foundation

nonisolated struct CourseKeyUnknownError: Error {}

@MainActor
final class OutboxSender {
    private let push: PushCoordinator
    private let addedCourseUpload: @MainActor (_ semester: String, _ courseNo: String) -> PushAPI.CourseUploadRequest?
    private let uploadsCourses: @MainActor () -> Bool
    private let isProtectedDataAvailable: @MainActor () -> Bool
    private let courses: CourseStore
    let kept: KeptValues
    var onCourseAddLanded: @MainActor (_ key: String) -> Void = { _ in }

    init(
        push: PushCoordinator,
        addedCourseUpload: @escaping @MainActor (_ semester: String, _ courseNo: String) -> PushAPI.CourseUploadRequest?,
        uploadsCourses: @escaping @MainActor () -> Bool,
        isProtectedDataAvailable: @escaping @MainActor () -> Bool,
        courses: CourseStore = .shared,
        kept: KeptValues? = nil
    ) {
        self.push = push
        self.addedCourseUpload = addedCourseUpload
        self.uploadsCourses = uploadsCourses
        self.isProtectedDataAvailable = isProtectedDataAvailable
        self.courses = courses
        self.kept = kept ?? KeptValues()
    }

    func send(_ op: SyncOp, for signIn: SignIn, hasNewerQueuedEdit: @MainActor (SyncOp) async -> Bool) async throws {
        switch op {
        case .courseOverride(let semester, let moodleId, let customName, let colorHex, let locale, let stamp):
            guard let (courseKey, courseNo) = courseKey(semester: semester, identity: moodleId) else {
                throw CourseKeyUnknownError()
            }
            let resolvedLocale = customName != nil ? (locale ?? Locale.current.language.languageCode?.identifier) : nil
            let reply = try await push.patchCourseOverride(
                courseKey: courseKey, colorHex: colorHex, customName: customName, locale: resolvedLocale, madeAt: stamp,
                for: signIn
            )
            guard !(await hasNewerQueuedEdit(op)) else { return }
            if colorHex != nil, !reply.applied.contains(.colorHex) {
                kept.colorKept(reply.colorHex, courseNo: courseNo, for: signIn)
            }
            if customName != nil, let resolvedLocale, !reply.applied.contains(.customName) {
                kept.nameKept(reply.customNames[resolvedLocale], courseNo: courseNo, locale: resolvedLocale, for: signIn)
            }

        case .assignmentOverride(_, let moodleAssignmentId, let localStatus, let stamp):
            let reply = try await push.patchAssignmentOverride(
                moodleAssignmentId: String(moodleAssignmentId), localStatus: localStatus, madeAt: stamp, for: signIn
            )
            if !reply.applied, !(await hasNewerQueuedEdit(op)) {
                kept.markKept(reply.localStatus, assignmentId: String(moodleAssignmentId), for: signIn)
            }

        case .courseIgnore(let semester, let courseNo, _, let moodleCourseId, let ignore, let stamp):
            let reply = try await push.patchCourseOverride(
                courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo),
                ignoreAssignments: ignore, moodleCourseId: moodleCourseId, madeAt: stamp, for: signIn
            )
            if ignore != nil, !reply.applied.contains(.ignoreAssignments), !(await hasNewerQueuedEdit(op)) {
                kept.ignoreKept(reply.ignoreAssignments, key: CourseTombstone.key(semester: semester, courseNo: courseNo), for: signIn)
            }

        case .courseDelete(let semester, let courseNo, let stamp):
            try await push.deleteCourse(
                courseKey: CourseTombstone.serverKey(semester: semester, courseNo: courseNo), madeAt: stamp, for: signIn
            )

        case .courseAdd(let semester, let courseNo, let stamp):
            guard isProtectedDataAvailable() else { throw CancellationError() }
            guard var request = addedCourseUpload(semester, courseNo) else { return }
            let key = CourseTombstone.serverKey(semester: semester, courseNo: courseNo)
            request.handAddedCourses = [PushAPI.CourseAdd(courseKey: key, hlc: PushAPI.clock(of: stamp))]
            guard try await push.uploadCoursesIfChanged(
                request, semester: semester, addedAt: stamp, for: signIn, while: uploadsCourses
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
        guard let course = Self.termAndNumber(of: identity, terms: terms) else { return nil }
        return (CourseTombstone.serverKey(semester: course.term, courseNo: course.courseNo), course.courseNo)
    }

    nonisolated static func identity(semester: String, courseNo: String, moodleIdNumber: String?) -> String {
        moodleIdNumber.flatMap { $0.isEmpty ? nil : $0 } ?? "\(semester)\(courseNo)"
    }

    nonisolated static func termAndNumber(of identity: String, terms: [String]) -> (term: String, courseNo: String)? {
        guard let term = terms.first(where: { identity.hasPrefix($0) && identity.count > $0.count }) else { return nil }
        return (term, String(identity.dropFirst(term.count)))
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

    func colorKept(_ hex: String?, courseNo: String, for signIn: SignIn) {
        let policy = policy()
        guard policy.switchedOn.contains("course_colors"), policy.sendsCourseOverride("course_colors"),
              let hex, let value = UInt32(hex.dropFirst(), radix: 16) else { return }
        colors.applyColors([(courseNo, value)], palette: TigerDuckTheme.coursePaletteHexes, for: signIn)
    }

    func nameKept(_ name: String?, courseNo: String, locale: String, for signIn: SignIn) {
        let policy = policy()
        guard policy.switchedOn.contains("course_names"), policy.sendsCourseOverride("course_names") else { return }
        let names = courses.loadCourseCustomNames()
        var updated = names
        var forCourse = updated[courseNo] ?? [:]
        if let name, !name.isEmpty { forCourse[locale] = name } else { forCourse.removeValue(forKey: locale) }
        updated[courseNo] = forCourse.isEmpty ? nil : forCourse
        if updated != names { courses.saveCourseCustomNames(updated, for: signIn) }
    }

    func markKept(_ status: String, assignmentId: String, for signIn: SignIn) {
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
        if archived != assignments.loadArchivedAssignmentIds() { assignments.replaceArchivedAssignmentIds(archived, for: signIn) }
        if completed != assignments.loadLocallyCompletedAssignmentIds() {
            assignments.replaceLocallyCompletedAssignmentIds(completed, for: signIn)
        }
    }

    func ignoreKept(_ ignoring: Bool, key: String, for signIn: SignIn) {
        guard policy().sendsCourseIgnores else { return }
        var ignored = assignments.loadIgnoredAssignmentCourses()
        if ignoring { ignored.insert(key) } else { ignored.remove(key) }
        if ignored != assignments.loadIgnoredAssignmentCourses() { assignments.replaceIgnoredAssignmentCourses(ignored, for: signIn) }
    }
}
