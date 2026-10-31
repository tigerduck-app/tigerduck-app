import Foundation

/// The school account's assignment files: the Moodle assignments of the last round, the closed
/// ones never submitted, and the user's marks (archived, done here, and the courses whose
/// assignments are ignored). `Stores/AssignmentStore.swift` reads and writes them.
final class AssignmentFiles: AccountScoped {
    private let cache: JSONFiles
    private let persistent: JSONFiles

    init(folders: CacheFolders = .app) {
        cache = folders.cacheFiles
        persistent = folders.persistentFiles
    }

    static func forgetAccount(in storage: AccountStorage) {
        storage.folders.cacheFiles.remove("assignments.json")
        storage.folders.cacheFiles.remove("closed_unsubmitted_assignments.json")
        storage.folders.persistentFiles.remove("archived_assignments.json")
        storage.folders.persistentFiles.remove("locally_completed_assignments.json")
        storage.folders.persistentFiles.remove("ignored_courses.json")
    }

    func saveAssignments(_ assignments: [SDAssignment]) {
        cache.save(assignments.map { CachedAssignment(from: $0) }, to: "assignments.json")
    }

    func loadAssignments(semester: String = CourseSelectionService.currentSemesterCode()) -> [SDAssignment] {
        let dtos: [CachedAssignment] = cache.load("assignments.json") ?? []
        let marks = assignmentMarks(semester: semester)
        return dtos.map { marks.apply(to: $0.toSDAssignment()) }
    }

    func assignmentMarks(semester: String) -> AssignmentMarks {
        AssignmentMarks(
            archivedIds: loadArchivedAssignmentIds(),
            locallyCompletedIds: loadLocallyCompletedAssignmentIds(),
            ignoredCourses: loadIgnoredAssignmentCourses(),
            semester: semester
        )
    }

    func loadClosedUnsubmittedAssignments() -> [String: Date] {
        cache.load("closed_unsubmitted_assignments.json") ?? [:]
    }

    func replaceClosedUnsubmittedAssignments(_ closed: [String: Date]) {
        cache.save(closed, to: "closed_unsubmitted_assignments.json")
    }

    // MARK: - Courses whose assignments are ignored

    func loadIgnoredAssignmentCourses() -> Set<String> {
        let keys: [String] = persistent.load("ignored_courses.json") ?? []
        return Set(keys)
    }

    func replaceIgnoredAssignmentCourses(_ keys: Set<String>) {
        persistent.save(keys.sorted(), to: "ignored_courses.json")
    }

    func setAssignmentsIgnored(_ ignored: Bool, semester: String, courseNo: String) {
        var keys = loadIgnoredAssignmentCourses()
        let key = CourseTombstone.key(semester: semester, courseNo: courseNo)
        if ignored { keys.insert(key) } else { keys.remove(key) }
        replaceIgnoredAssignmentCourses(keys)
    }

    func clearIgnoredAssignmentCourses(semester: String) {
        let prefix = CourseTombstone.key(semester: semester, courseNo: "")
        replaceIgnoredAssignmentCourses(loadIgnoredAssignmentCourses().filter { !$0.hasPrefix(prefix) })
    }

    // MARK: - Marks

    func addArchivedAssignmentId(_ id: String) {
        replaceArchivedAssignmentIds(loadArchivedAssignmentIds().union([id]))
    }

    func removeArchivedAssignmentId(_ id: String) {
        replaceArchivedAssignmentIds(loadArchivedAssignmentIds().subtracting([id]))
    }

    func loadArchivedAssignmentIds() -> Set<String> {
        let ids: [String] = persistent.load("archived_assignments.json") ?? []
        return Set(ids)
    }

    func replaceArchivedAssignmentIds(_ ids: Set<String>) {
        persistent.save(Array(ids), to: "archived_assignments.json")
    }

    func addLocallyCompletedAssignmentId(_ id: String) {
        replaceLocallyCompletedAssignmentIds(loadLocallyCompletedAssignmentIds().union([id]))
    }

    func removeLocallyCompletedAssignmentId(_ id: String) {
        replaceLocallyCompletedAssignmentIds(loadLocallyCompletedAssignmentIds().subtracting([id]))
    }

    func loadLocallyCompletedAssignmentIds() -> Set<String> {
        let ids: [String] = persistent.load("locally_completed_assignments.json") ?? []
        return Set(ids)
    }

    func replaceLocallyCompletedAssignmentIds(_ ids: Set<String>) {
        persistent.save(Array(ids), to: "locally_completed_assignments.json")
    }
}

struct AssignmentMarks {
    let archivedIds: Set<String>
    let locallyCompletedIds: Set<String>
    let ignoredCourses: Set<String>
    let semester: String

    func apply(to assignment: SDAssignment) -> SDAssignment {
        if archivedIds.contains(assignment.assignmentId) { assignment.isArchived = true }
        if locallyCompletedIds.contains(assignment.assignmentId) { assignment.isLocallyCompleted = true }
        let term = assignment.semester ?? semester
        if ignoredCourses.contains(CourseTombstone.key(semester: term, courseNo: assignment.courseNo)) {
            assignment.isArchived = true
            assignment.isLocallyCompleted = false
            assignment.isIgnoredByCourse = true
        }
        return assignment
    }
}

private struct CachedAssignment: Codable {
    let assignmentId: String
    let courseNo: String
    let courseName: String
    let title: String
    let dueDate: Date
    let isCompleted: Bool
    let moodleUrl: String?
    let cutoffDate: Date?
    let submittedAt: Date?
    let originalDueDate: Date?
    let extensionDueDate: Date?
    let semester: String?

    init(from assignment: SDAssignment) {
        assignmentId = assignment.assignmentId
        courseNo = assignment.courseNo
        courseName = assignment.courseName
        title = assignment.title
        dueDate = assignment.dueDate
        isCompleted = assignment.isCompleted
        moodleUrl = assignment.moodleUrl
        cutoffDate = assignment.cutoffDate
        submittedAt = assignment.submittedAt
        originalDueDate = assignment.originalDueDate
        extensionDueDate = assignment.extensionDueDate
        semester = assignment.semester
    }

    func toSDAssignment() -> SDAssignment {
        SDAssignment(
            assignmentId: assignmentId,
            courseNo: courseNo,
            courseName: courseName,
            title: title,
            dueDate: originalDueDate ?? dueDate,
            isCompleted: isCompleted,
            moodleUrl: moodleUrl,
            cutoffDate: cutoffDate,
            submittedAt: submittedAt,
            extensionDueDate: extensionDueDate,
            semester: semester
        )
    }
}

