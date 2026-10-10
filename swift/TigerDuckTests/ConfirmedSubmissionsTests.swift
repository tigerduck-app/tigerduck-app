import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ConfirmedSubmissionsTests {
    @Test("a round skips only submissions Moodle confirmed with a time")
    func onlyTimedMoodleSubmissionsAreSkipped() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let submitted = due - 3600
        let cached = [
            SDAssignment(assignmentId: "1", courseNo: "CS1", courseName: "", title: "", dueDate: due,
                         isCompleted: true, submittedAt: submitted),
            SDAssignment(assignmentId: "2", courseNo: "CS1", courseName: "", title: "", dueDate: due,
                         isCompleted: true),
            SDAssignment(assignmentId: "3", courseNo: "CS1", courseName: "", title: "", dueDate: due,
                         submittedAt: submitted),
            SDAssignment(assignmentId: "4", courseNo: "CS1", courseName: "", title: "", dueDate: due,
                         isLocallyCompleted: true),
        ]
        #expect(AppServiceBridge.confirmedSubmissions(in: cached) == ["1": submitted])
    }
}
