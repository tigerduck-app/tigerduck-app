import Foundation
import Observation

enum AssignmentEdit {
    case setArchived(id: String, Bool)
    case setCompleted(id: String, Bool)
    case ignoreCourse(courseNo: String, semester: String, ignored: Bool)
}

@Observable
final class AssignmentStore {
    static let shared = AssignmentStore()

    typealias Assignment = SDAssignment
    typealias CalendarEvent = SDCalendarEvent
    typealias CalendarEventSource = EventSource

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

    func noteChange() {
        revision &+= 1
    }

    private func observe() {
        _ = revision
    }

    @discardableResult
    private func write(_ signIn: SignIn, _ body: (AssignmentFiles) -> Void) -> Bool {
        guard signIn.isCurrent else { return false }
        body(files)
        revision &+= 1
        return true
    }

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

    func loadClosedUnsubmittedAssignments() -> ClosedUnsubmittedAnswerTimes {
        observe()
        return files.loadClosedUnsubmittedAssignments()
    }

    func loadCalendarEvents() -> [SDCalendarEvent] {
        observe()
        return events.loadCalendarEvents()
    }

    @discardableResult
    func saveAssignments(_ assignments: [SDAssignment], for signIn: SignIn) -> Bool {
        write(signIn) { $0.saveAssignments(assignments) }
    }

    func replaceArchivedAssignmentIds(_ ids: Set<String>, for signIn: SignIn) {
        write(signIn) { $0.replaceArchivedAssignmentIds(ids) }
    }

    func replaceLocallyCompletedAssignmentIds(_ ids: Set<String>, for signIn: SignIn) {
        write(signIn) { $0.replaceLocallyCompletedAssignmentIds(ids) }
    }

    func replaceIgnoredAssignmentCourses(_ keys: Set<String>, for signIn: SignIn) {
        write(signIn) { $0.replaceIgnoredAssignmentCourses(keys) }
    }

    func clearIgnoredAssignmentCourses(semester: String, for signIn: SignIn) {
        write(signIn) { $0.clearIgnoredAssignmentCourses(semester: semester) }
    }

    func replaceClosedUnsubmittedAssignments(_ closed: ClosedUnsubmittedAnswerTimes, for signIn: SignIn) {
        write(signIn) { $0.replaceClosedUnsubmittedAssignments(closed) }
    }

    @discardableResult
    func saveCalendarEvents(_ calendarEvents: [SDCalendarEvent], for signIn: SignIn) -> Bool {
        guard signIn.isCurrent else { return false }
        events.saveCalendarEvents(calendarEvents)
        revision &+= 1
        return true
    }

    func apply(_ edit: AssignmentEdit, for signIn: SignIn) {
        switch edit {
        case let .setArchived(id, archived):
            write(signIn) { archived ? $0.addArchivedAssignmentId(id) : $0.removeArchivedAssignmentId(id) }
        case let .setCompleted(id, completed):
            write(signIn) { completed ? $0.addLocallyCompletedAssignmentId(id) : $0.removeLocallyCompletedAssignmentId(id) }
        case let .ignoreCourse(courseNo, semester, ignored):
            write(signIn) { $0.setAssignmentsIgnored(ignored, semester: semester, courseNo: courseNo) }
        }
    }
}
