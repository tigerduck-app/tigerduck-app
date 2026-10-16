#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// What an assignment's page shows of its submission before and after the fetch answers. Every
/// name here is made up.
@MainActor
struct MoodleAssignmentPageTests {
    private static let due = Date(timeIntervalSince1970: 1_790_600_000)

    private static let file = MoodleFile(
        name: "hw.pdf", size: 870_400,
        url: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/assignsubmission_file/submission_files/5501/hw.pdf",
        mimeType: "application/pdf", modified: due, path: "/"
    )

    private static func assignment(submittedAt: Date?) -> SDAssignment {
        SDAssignment(
            assignmentId: "701", courseNo: "CS3105301", courseName: "Data Structures", title: "HW 2", dueDate: due,
            isCompleted: submittedAt != nil, submittedAt: submittedAt
        )
    }

    private static func submission(
        _ status: String?, modified: Date? = due - 3600, files: [MoodleFile] = [], text: String? = nil
    ) -> MoodleAssignmentSubmission {
        MoodleAssignmentSubmission(
            status: status, modified: modified, files: files, onlineText: text, id: 5501, takesComments: false,
            groupId: nil
        )
    }

    @Test("the submission time is the fetched one, and before the first fetch answers, the one the round found")
    func submittedAt() {
        let foundByRound = Self.due - 7200
        let fetched = Self.due - 3600
        let assignment = Self.assignment(submittedAt: foundByRound)

        #expect(MoodleAssignmentView.submittedAt(of: assignment, submission: nil) == foundByRound)
        #expect(MoodleAssignmentView.submittedAt(of: assignment, submission: Self.submission("submitted", modified: fetched))
            == fetched)
        #expect(MoodleAssignmentView.submittedAt(of: assignment, submission: Self.submission("draft", modified: fetched)) == nil)
        #expect(MoodleAssignmentView.submittedAt(of: Self.assignment(submittedAt: nil), submission: nil) == nil)
    }

    @Test("the not-submitted line shows only for a submission with nothing in it that is not submitted")
    func notSubmittedLine() {
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission(nil)))
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission("new")))
        #expect(MoodleAssignmentView.showsNotSubmitted(Self.submission("reopened")))
        #expect(!MoodleAssignmentView.showsNotSubmitted(Self.submission("draft", files: [Self.file])))
        #expect(!MoodleAssignmentView.showsNotSubmitted(Self.submission("draft", text: "<p>Half done</p>")))
        #expect(!MoodleAssignmentView.showsNotSubmitted(Self.submission("submitted")))
    }
}
#endif
