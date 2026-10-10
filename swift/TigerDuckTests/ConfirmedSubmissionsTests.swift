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

    @Test("a failed status keeps the cached submission, an answered one replaces it")
    func onlyUnansweredAssignmentsKeepTheirState() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let submitted = due - 3600
        let cached = ["1", "2"].map {
            SDAssignment(assignmentId: $0, courseNo: "CS1", courseName: "", title: "", dueDate: due,
                         isCompleted: true, submittedAt: submitted)
        }
        let fresh = ["1", "2"].map {
            SDAssignment(assignmentId: $0, courseNo: "CS1", courseName: "", title: "", dueDate: due)
        }
        let merged = AppServiceBridge.preserveCompletionState(
            freshAssignments: fresh, cachedAssignments: cached, answeredIds: ["2"]
        )
        #expect(merged.map(\.isCompleted) == [true, false])
        #expect(merged.map(\.submittedAt) == [submitted, nil])
    }
}
