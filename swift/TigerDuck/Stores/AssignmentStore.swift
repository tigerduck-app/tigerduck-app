import Foundation
import Observation

/// A user's mark on an assignment, or on every assignment of a course.
enum AssignmentEdit {
    case setArchived(id: String, Bool)
    /// Done here, whatever Moodle says.
    case setCompleted(id: String, Bool)
    case ignoreCourse(courseNo: String, semester: String, ignored: Bool)
}

/// The school account's assignments, their marks and the calendar's events, read and written
/// through `AssignmentFiles` and `CalendarEventFiles`. Every write bumps `revision` and every read
/// observes it; user marks enter as `AssignmentEdit` values through `apply`.
@Observable
final class AssignmentStore {
    static let shared = AssignmentStore()

    @ObservationIgnored let files: AssignmentFiles
    @ObservationIgnored let events: CalendarEventFiles
    private(set) var revision = 0

    init(files: AssignmentFiles = AssignmentFiles(), events: CalendarEventFiles = CalendarEventFiles()) {
        self.files = files
        self.events = events
    }

    convenience init(folders: CacheFolders) {
        self.init(files: AssignmentFiles(folders: folders), events: CalendarEventFiles(folders: folders))
    }

    /// Something outside the store changed the files, as a sign-out does.
    func noteChange() {
        revision &+= 1
    }

    private func observe() {
        _ = revision
    }

    private func write(_ body: (AssignmentFiles) -> Void) {
        body(files)
        revision &+= 1
    }

    // MARK: - Reads

    func loadAssignments(semester: String = CourseSelectionService.currentSemesterCode()) -> [SDAssignment] {
        observe()
        return files.loadAssignments(semester: semester)
    }

    func assignmentMarks(semester: String) -> AssignmentMarks {
        observe()
        return files.assignmentMarks(semester: semester)
    }

    func loadArchivedAssignmentIds() -> Set<String> {
        observe()
        return files.loadArchivedAssignmentIds()
    }

    func loadLocallyCompletedAssignmentIds() -> Set<String> {
        observe()
        return files.loadLocallyCompletedAssignmentIds()
    }

    func loadIgnoredAssignmentCourses() -> Set<String> {
        observe()
        return files.loadIgnoredAssignmentCourses()
    }

    func loadClosedUnsubmittedAssignments() -> [String: Date] {
        observe()
        return files.loadClosedUnsubmittedAssignments()
    }

    func loadCalendarEvents() -> [SDCalendarEvent] {
        observe()
        return events.loadCalendarEvents()
    }

    // MARK: - Writes of fetched and synced state

    func saveAssignments(_ assignments: [SDAssignment]) { write { $0.saveAssignments(assignments) } }
    func replaceArchivedAssignmentIds(_ ids: Set<String>) { write { $0.replaceArchivedAssignmentIds(ids) } }
    func replaceLocallyCompletedAssignmentIds(_ ids: Set<String>) { write { $0.replaceLocallyCompletedAssignmentIds(ids) } }
    func replaceIgnoredAssignmentCourses(_ keys: Set<String>) { write { $0.replaceIgnoredAssignmentCourses(keys) } }
    func clearIgnoredAssignmentCourses(semester: String) { write { $0.clearIgnoredAssignmentCourses(semester: semester) } }

    func replaceClosedUnsubmittedAssignments(_ closed: [String: Date]) {
        write { $0.replaceClosedUnsubmittedAssignments(closed) }
    }

    func saveCalendarEvents(_ calendarEvents: [SDCalendarEvent]) {
        events.saveCalendarEvents(calendarEvents)
        revision &+= 1
    }

    // MARK: - Edits

    /// Applies a user's mark to the files as they are now.
    func apply(_ edit: AssignmentEdit) {
        switch edit {
        case let .setArchived(id, archived):
            write { archived ? $0.addArchivedAssignmentId(id) : $0.removeArchivedAssignmentId(id) }
        case let .setCompleted(id, completed):
            write { completed ? $0.addLocallyCompletedAssignmentId(id) : $0.removeLocallyCompletedAssignmentId(id) }
        case let .ignoreCourse(courseNo, semester, ignored):
            write { $0.setAssignmentsIgnored(ignored, semester: semester, courseNo: courseNo) }
        }
    }
}
