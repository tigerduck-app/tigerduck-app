import Foundation
import Testing
@testable import TigerDuck

struct MoodleSubmissionStatusDecodingTests {
    private static func status(_ json: String) throws -> MoodleSubmissionStatus {
        try JSONDecoder()
            .decode(RawSubmissionStatusResponse.self, from: Data(json.utf8))
            .toMoodleSubmissionStatus(assignId: 7)
    }

    @Test("a student's own submission decides an individual assignment")
    func individualSubmission() throws {
        let submitted = try Self.status(#"{"lastattempt":{"submission":{"status":"submitted","timemodified":1790000000}}}"#)
        #expect(submitted.isSubmitted)
        #expect(submitted.submittedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(try !Self.status(#"{"lastattempt":{"submission":{"status":"draft"}}}"#).isSubmitted)
    }

    @Test("a teammate's submission counts when the student's own record is unsubmitted or has no status")
    func teamSubmission() throws {
        let ownNew = try Self.status(#"{"lastattempt":{"submission":{"status":"new"},"teamsubmission":{"status":"submitted","timemodified":1790000100}}}"#)
        #expect(ownNew.isSubmitted)
        #expect(ownNew.submittedAt == Date(timeIntervalSince1970: 1_790_000_100))
        #expect(try Self.status(#"{"lastattempt":{"submission":{},"teamsubmission":{"status":"submitted"}}}"#).isSubmitted)
        #expect(try Self.status(#"{"lastattempt":{"teamsubmission":{"status":"submitted"}}}"#).isSubmitted)
    }

    @Test("feedback in a shape the app does not expect costs the grade, not the submission's status")
    func unreadableFeedback() throws {
        let json = #"{"lastattempt":{"submission":{"status":"submitted","timemodified":1790000000}},"#
            + #""feedback":{"gradefordisplay":85,"gradeddate":"soon","plugins":"none"}}"#
        let answer = try JSONDecoder().decode(RawSubmissionStatusResponse.self, from: Data(json.utf8))

        let status = answer.toMoodleSubmissionStatus(assignId: 7)
        #expect(status.isSubmitted)
        #expect(status.submittedAt == Date(timeIntervalSince1970: 1_790_000_000))
        #expect(answer.submission.isSubmitted)
        #expect(answer.submission.grade == nil)
    }

    @Test("an unsubmitted team stays unsubmitted, and a missing attempt has no status")
    func unsubmittedTeam() throws {
        let team = try Self.status(#"{"lastattempt":{"submission":{},"teamsubmission":{"status":"new"}}}"#)
        #expect(team.submissionStatus == "new")
        #expect(!team.isSubmitted)
        #expect(try Self.status(#"{}"#).submissionStatus == nil)
    }
}
