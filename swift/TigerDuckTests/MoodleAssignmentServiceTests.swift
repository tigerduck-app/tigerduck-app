import Foundation
import Testing
@testable import TigerDuck

struct MoodleAssignmentServiceTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    private static func endpoint(_ function: String, token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(function)&wstoken=\(token)")!
    }

    private static func answer(_ body: String, function: String, token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: endpoint(function, token: token))
    }

    private static func body(of function: String, token: String) throws -> String? {
        let request = try #require(SettingsAPIStub.requests(for: endpoint(function, token: token)).first)
        return SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func file(_ name: String, area: String, item: Int, size: Int, type: String, time: Int) -> String {
        #"{"filename": "\#(name)", "filepath": "/", "filesize": \#(size), "#
            + #""fileurl": "https://moodle-stub.invalid/webservice/pluginfile.php/123/\#(area)/\#(item)/\#(name)", "#
            + #""timemodified": \#(time), "mimetype": "\#(type)", "isexternalfile": false}"#
    }

    static let assignments = #"""
    {"courses": [{"id": 20119, "fullname": "Data Structures", "shortname": "DS", "timemodified": 1790000000,
      "assignments": [
        {"id": 701, "cmid": 9101, "course": 20119, "name": "HW 2: Linked lists", "nosubmissions": 0,
         "submissiondrafts": 0, "sendnotifications": 0, "sendlatenotifications": 0, "duedate": 1790600000,
         "allowsubmissionsfromdate": 1790000000, "grade": 100, "timemodified": 1790000000, "cutoffdate": 0,
         "teamsubmission": 0, "requireallteammemberssubmit": 0, "maxattempts": -1, "configs": [],
         "intro": "<p>Implement a <strong>singly linked list</strong>.</p>", "introformat": 1, "introfiles": [],
         "introattachments": [{"filename": "spec.pdf", "filepath": "/", "filesize": 1258291,
           "fileurl": "https://moodle-stub.invalid/webservice/pluginfile.php/123/mod_assign/introattachment/0/spec.pdf",
           "timemodified": 1790000000, "mimetype": "application/pdf", "isexternalfile": false}]},
        {"id": 702, "cmid": 9102, "course": 20119, "name": "Final project", "nosubmissions": 0,
         "duedate": 1791000000, "allowsubmissionsfromdate": 0, "cutoffdate": 1791100000, "teamsubmission": 1,
         "requireallteammemberssubmit": 0, "configs": [], "intro": "", "introformat": 1, "introattachments": []}
      ]}], "warnings": []}
    """#

    @Test("the assignment list keeps each one's description, attachments and whether a group submits together")
    func assignmentRecords() async throws {
        let token = UUID().uuidString
        Self.answer(Self.assignments, function: "mod_assign_get_assignments", token: token)

        let records = try await MoodleAssignmentService.fetchAssignments(
            courseIds: [20119], tokens: .init(stored: { token }, renew: { _ in token }),
            session: Self.session(), siteURL: Self.site
        )

        #expect(records.map(\.assignId) == [701, 702])
        #expect(records[0].intro == "<p>Implement a <strong>singly linked list</strong>.</p>")
        #expect(records[0].introAttachments == [MoodleFile(
            name: "spec.pdf", size: 1_258_291,
            url: "https://moodle-stub.invalid/webservice/pluginfile.php/123/mod_assign/introattachment/0/spec.pdf",
            mimeType: "application/pdf", modified: Date(timeIntervalSince1970: 1_790_000_000), path: "/"
        )])
        #expect(!records[0].teamSubmission)
        #expect(records[1].introAttachments.isEmpty)
        #expect(records[1].teamSubmission)
    }

    private static func submission(_ json: String) throws -> MoodleAssignmentSubmission {
        try JSONDecoder().decode(RawSubmissionStatusResponse.self, from: Data(json.utf8)).submission
    }

    @Test("an individual submission brings its files, its online text, its time and that it takes comments")
    func individualSubmission() throws {
        let submission = try Self.submission(#"""
        {"lastattempt": {
          "submission": {"id": 5501, "userid": 42, "attemptnumber": 0, "timecreated": 1790400000,
            "timemodified": 1790500000, "timestarted": null, "status": "submitted", "groupid": 0,
            "assignment": 701, "latest": 1, "plugins": [
              {"type": "file", "name": "File submissions", "fileareas": [{"area": "submission_files", "files": [
                \#(Self.file("hw2.pdf", area: "assignsubmission_file/submission_files", item: 5501, size: 870400,
                             type: "application/pdf", time: 1790500000))]}]},
              {"type": "comments", "name": "Submission comments"},
              {"type": "onlinetext", "name": "Online text",
               "fileareas": [{"area": "submissions_onlinetext", "files": [
                 \#(Self.file("chart.png", area: "assignsubmission_onlinetext/submissions_onlinetext", item: 5501,
                              size: 4096, type: "image/png", time: 1790500000))]}],
               "editorfields": [{"name": "onlinetext", "description": "Online text submissions",
                 "text": "<p>See the attached report.</p>", "format": 1}]}
            ]},
          "submissiongroupmemberswhoneedtosubmit": [], "submissionsenabled": true, "locked": false, "graded": false,
          "canedit": true, "caneditowner": true, "cansubmit": false, "extensionduedate": null, "timelimit": 0,
          "blindmarking": false, "gradingstatus": "notgraded", "usergroups": []},
         "warnings": []}
        """#)

        #expect(submission.isSubmitted)
        #expect(submission.submittedAt == Date(timeIntervalSince1970: 1_790_500_000))
        #expect(submission.files.map(\.name) == ["hw2.pdf"])
        #expect(submission.files.first?.url
            == "https://moodle-stub.invalid/webservice/pluginfile.php/123/assignsubmission_file/submission_files/5501/hw2.pdf")
        #expect(submission.onlineText == "<p>See the attached report.</p>")
        #expect(submission.id == 5501)
        #expect(submission.takesComments)
        #expect(submission.groupId == nil)
        #expect(submission.grade == nil)
    }

    @Test("a graded submission brings the grade as Moodle writes it for the student, when it was graded and the feedback")
    func gradedSubmission() throws {
        let submission = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5501, "timemodified": 1790500000, "status": "submitted", "plugins": []},
          "graded": true, "gradingstatus": "graded"},
         "feedback": {
           "grade": {"id": 801, "assignment": 701, "userid": 42, "attemptnumber": 0, "timecreated": 1790600000,
             "timemodified": 1790700000, "grader": 7, "grade": "85.00000"},
           "gradefordisplay": "85.00&nbsp;/&nbsp;100.00", "gradeddate": 1790700000,
           "plugins": [
             {"type": "comments", "name": "Feedback comments",
              "fileareas": [{"area": "feedback", "files": [
                \#(Self.file("case7.png", area: "assignfeedback_comments/feedback", item: 801, size: 2048,
                             type: "image/png", time: 1790700000))]}],
              "editorfields": [{"name": "comments", "description": "Feedback comments", "format": 1,
                "text": "<p>Case 7 misses the empty tree.</p><p><img src=\"@@PLUGINFILE@@/case7.png\" alt=\"case 7\"> <img src=\"@@PLUGINFILE@@/gone.png\" alt=\"gone\"></p>"}]},
             {"type": "file", "name": "File feedback", "fileareas": [{"area": "feedback_files", "files": []}]}
           ]},
         "warnings": []}
        """#)

        let grade = try #require(submission.grade)
        #expect(grade.grade == "85.00 / 100.00")
        #expect(grade.gradedAt == Date(timeIntervalSince1970: 1_790_700_000))
        let feedback = try #require(grade.feedback)
        #expect(feedback.contains("Case 7 misses the empty tree."))
        #expect(feedback.contains("https://moodle-stub.invalid/webservice/pluginfile.php/123/assignfeedback_comments/feedback/801/case7.png"))
        #expect(!feedback.contains("gone"))
    }

    @Test("feedback without a grade keeps the feedback, and a grade of - with empty feedback is no grade")
    func feedbackWithoutAGrade() throws {
        let feedbackOnly = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5501, "timemodified": 1790500000, "status": "submitted"}},
         "feedback": {"gradefordisplay": null, "gradeddate": null, "plugins": [
           {"type": "comments", "editorfields": [{"name": "comments", "text": "<p>See me after class.</p>", "format": 1}]}]}}
        """#)
        #expect(feedbackOnly.grade == MoodleAssignmentGrade(grade: nil, gradedAt: nil, feedback: "<p>See me after class.</p>"))

        let nothing = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5501, "timemodified": 1790500000, "status": "submitted"}},
         "feedback": {"gradefordisplay": "-", "gradeddate": 0, "plugins": [
           {"type": "comments", "editorfields": [{"name": "comments", "text": "<p></p>", "format": 1}]}]}}
        """#)
        #expect(nothing.grade == nil)
    }

    @Test("a team assignment shows what the group handed in, with the group it is for")
    func teamSubmission() throws {
        let submission = try Self.submission(#"""
        {"lastattempt": {
          "submission": {"id": 5601, "userid": 42, "timemodified": 1790300000, "status": "new", "groupid": 0,
            "assignment": 702, "latest": 1, "plugins": [
              {"type": "file", "fileareas": [{"area": "submission_files", "files": []}]},
              {"type": "comments", "name": "Submission comments"}]},
          "teamsubmission": {"id": 5600, "userid": 0, "timemodified": 1790900000, "status": "submitted",
            "groupid": 31, "assignment": 702, "latest": 1, "plugins": [
              {"type": "file", "fileareas": [{"area": "submission_files", "files": [
                \#(Self.file("project.zip", area: "assignsubmission_file/submission_files", item: 5600, size: 2048,
                             type: "application/zip", time: 1790900000))]}]},
              {"type": "comments", "name": "Submission comments"}]},
          "submissiongroup": 31, "submissionsenabled": true, "gradingstatus": "notgraded", "usergroups": [31]},
         "warnings": []}
        """#)

        #expect(submission.id == 5600)
        #expect(submission.files.map(\.name) == ["project.zip"])
        #expect(submission.submittedAt == Date(timeIntervalSince1970: 1_790_900_000))
        #expect(submission.groupId == 31)
        #expect(submission.takesComments)
    }

    @Test("where every member must submit, the page follows the student's own record, as the round does")
    func everyMemberSubmits() throws {
        let submission = try Self.submission(#"""
        {"lastattempt": {
          "submission": {"id": 5601, "timemodified": 1790800000, "status": "submitted", "plugins": [
            {"type": "comments", "name": "Submission comments"}]},
          "teamsubmission": {"id": 5600, "timemodified": 1790700000, "status": "draft", "plugins": [
            {"type": "file", "fileareas": [{"area": "submission_files", "files": [
              \#(Self.file("project.zip", area: "assignsubmission_file/submission_files", item: 5600, size: 2048,
                           type: "application/zip", time: 1790700000))]}]}]},
          "submissiongroup": 31, "submissiongroupmemberswhoneedtosubmit": [43]},
         "warnings": []}
        """#)

        #expect(submission.id == 5601)
        #expect(submission.submittedAt == Date(timeIntervalSince1970: 1_790_800_000))
        #expect(submission.takesComments)
    }

    @Test("online text points its images and links at its own files, and drops an image with no file")
    func onlineTextFiles() throws {
        let submission = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5501, "timemodified": 1790500000, "status": "submitted", "plugins": [
          {"type": "onlinetext", "fileareas": [{"area": "submissions_onlinetext", "files": [
            \#(Self.file("chart.png", area: "assignsubmission_onlinetext/submissions_onlinetext", item: 5501,
                         size: 4096, type: "image/png", time: 1790500000)),
            {"filename": "notes v2.pdf", "filepath": "/", "filesize": 100, "mimetype": "application/pdf",
             "fileurl": "https://moodle-stub.invalid/webservice/pluginfile.php/123/assignsubmission_onlinetext/submissions_onlinetext/5501/notes%20v2.pdf",
             "timemodified": 1790500000}]}],
           "editorfields": [{"name": "onlinetext", "format": 1, "text":
             "<p>Chart: <img src=\"@@PLUGINFILE@@/chart.png\" alt=\"chart\"> <img src=\"@@PLUGINFILE@@/gone.png\" alt=\"gone\"></p><p><a href=\"@@PLUGINFILE@@/notes%20v2.pdf\">Notes</a> <a href=\"@@PLUGINFILE@@/old.pdf\">Old notes</a></p>"}]}
        ]}}}
        """#)

        let text = try #require(submission.onlineText)
        #expect(!text.contains("@@PLUGINFILE@@"))
        #expect(text.contains(
            "https://moodle-stub.invalid/webservice/pluginfile.php/123/assignsubmission_onlinetext/submissions_onlinetext/5501/chart.png"
        ))
        #expect(text.contains("submissions_onlinetext/5501/notes%20v2.pdf"))
        #expect(!text.contains("gone"))
        #expect(text.contains("Old notes"))
    }

    @Test("with no record on Moodle yet, nothing is handed in and there is nothing to comment on")
    func noSubmission() throws {
        let submission = try Self.submission(#"""
        {"lastattempt": {"submissionsenabled": true, "locked": false, "graded": false, "canedit": true,
          "cansubmit": false, "gradingstatus": "notgraded", "usergroups": []}, "warnings": []}
        """#)

        #expect(submission.status == nil)
        #expect(!submission.isSubmitted)
        #expect(submission.files.isEmpty)
        #expect(submission.onlineText == nil)
        #expect(submission.id == nil)
        #expect(!submission.takesComments)
    }

    @Test("a draft keeps its online text but has no submission time, and empty online text counts as none")
    func draftAndEmptyText() throws {
        let draft = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5701, "timemodified": 1790400000, "status": "draft", "plugins": [
          {"type": "onlinetext", "editorfields": [{"name": "onlinetext", "text": "<p>Half done</p>", "format": 1}]}
        ]}}}
        """#)
        #expect(draft.onlineText == "<p>Half done</p>")
        #expect(draft.modified == Date(timeIntervalSince1970: 1_790_400_000))
        #expect(draft.submittedAt == nil)

        let empty = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5702, "timemodified": 1790400000, "status": "submitted", "plugins": [
          {"type": "onlinetext", "editorfields": [{"name": "onlinetext", "text": "<p></p>", "format": 1}]}
        ]}}}
        """#)
        #expect(empty.onlineText == nil)

        let imageOnly = try Self.submission(#"""
        {"lastattempt": {"submission": {"id": 5703, "timemodified": 1790400000, "status": "submitted", "plugins": [
          {"type": "onlinetext", "fileareas": [{"area": "submissions_onlinetext", "files": [
            \#(Self.file("chart.png", area: "assignsubmission_onlinetext/submissions_onlinetext", item: 5703,
                         size: 4096, type: "image/png", time: 1790400000))]}],
           "editorfields": [{"name": "onlinetext", "text": "<p><img src=\"@@PLUGINFILE@@/chart.png\"></p>", "format": 1}]}
        ]}}}
        """#)
        #expect(imageOnly.onlineText != nil)
    }

    @Test("a student's extension comes with the submission and its status, and a null or zero one is none")
    func studentExtension() throws {
        func response(_ extensionDate: String) throws -> RawSubmissionStatusResponse {
            try JSONDecoder().decode(RawSubmissionStatusResponse.self, from: Data(#"""
            {"lastattempt": {"submission": {"id": 5501, "status": "new", "timemodified": 0, "plugins": []},
              "gradingstatus": "notgraded", "extensionduedate": \#(extensionDate)}}
            """#.utf8))
        }
        let extended = try response("1790700000")
        #expect(extended.submission.extensionDueDate == Date(timeIntervalSince1970: 1_790_700_000))
        #expect(extended.toMoodleSubmissionStatus(assignId: 701).extensionDueDate == Date(timeIntervalSince1970: 1_790_700_000))
        for none in ["null", "0"] {
            #expect(try response(none).submission.extensionDueDate == nil)
            #expect(try response(none).toMoodleSubmissionStatus(assignId: 701).extensionDueDate == nil)
        }
    }

    @Test("comments are asked for on the assignment's module and the submission's record, and read oldest first")
    func comments() async throws {
        let token = UUID().uuidString
        Self.answer(#"""
        {"comments": [
          {"id": 902, "content": "<div class=\"text_to_html\">Thanks, page 2 is the corrected one.</div>", "format": 1,
           "timecreated": 1790510000, "strftimeformat": "%A, %d %B %Y, %I:%M %p",
           "profileurl": "https://moodle-stub.invalid/user/view.php?id=42&course=20119",
           "fullname": "B11399001 @ Tiger Duck", "time": "Friday, 18 October 2026, 9:05 PM",
           "avatar": "https://moodle-stub.invalid/theme/image.php/moove/core/1/u/f2", "userid": 42, "delete": true},
          {"id": 901, "content": "<div class=\"text_to_html\">Please check page 2.</div>", "format": 1,
           "timecreated": 1790505000, "fullname": "T00001 @ Duck Teacher", "userid": 7, "delete": false}
        ], "count": 2, "perpage": 15, "canpost": true, "warnings": []}
        """#, function: MoodleAssignmentService.commentsFunction, token: token)

        let comments = try await MoodleAssignmentService.comments(
            cmid: 9101, submissionId: 5501, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(try Self.body(of: MoodleAssignmentService.commentsFunction, token: token)
            == "contextlevel=module&instanceid=9101&component=assignsubmission_comments&itemid=5501&area=submission_comments&page=0")
        #expect(comments == [
            MoodleSubmissionComment(
                id: 901, authorName: "T00001 @ Duck Teacher", created: Date(timeIntervalSince1970: 1_790_505_000),
                content: "<div class=\"text_to_html\">Please check page 2.</div>"
            ),
            MoodleSubmissionComment(
                id: 902, authorName: "B11399001 @ Tiger Duck", created: Date(timeIntervalSince1970: 1_790_510_000),
                content: "<div class=\"text_to_html\">Thanks, page 2 is the corrected one.</div>"
            ),
        ])
    }

    private static func commentsPage(_ ids: [Int], count: Int) -> String {
        let comments = ids.map { id in
            #"{"id": \#(id), "content": "<p>Note \#(id)</p>", "format": 1, "timecreated": \#(1_790_500_000 + id), "#
                + #""fullname": "T00001 @ Duck Teacher", "userid": 7, "delete": false}"#
        }
        return #"{"comments": [\#(comments.joined(separator: ", "))], "count": \#(count), "perpage": 15, "#
            + #""canpost": true, "warnings": []}"#
    }

    private static func pages(asked token: String) -> [String] {
        SettingsAPIStub.requests(for: endpoint(MoodleAssignmentService.commentsFunction, token: token)).compactMap {
            SettingsAPIStub.bodyData(from: $0).flatMap { String(data: $0, encoding: .utf8) }?
                .components(separatedBy: "&").first { $0.hasPrefix("page=") }
        }
    }

    @Test("comments past Moodle's first page are asked for a page at a time, and the first once more when one came in meanwhile")
    func commentPages() async throws {
        let token = UUID().uuidString
        let function = MoodleAssignmentService.commentsFunction
        Self.answer(Self.commentsPage(Array((3...17).reversed()), count: 17), function: function, token: token)
        Self.answer(Self.commentsPage([3, 2, 1], count: 18), function: function, token: token)
        Self.answer(Self.commentsPage([], count: 18), function: function, token: token)
        Self.answer(Self.commentsPage(Array((4...18).reversed()), count: 18), function: function, token: token)

        let comments = try await MoodleAssignmentService.comments(
            cmid: 9101, submissionId: 5501, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(comments.map(\.id) == Array(1...18))
        #expect(Self.pages(asked: token) == ["page=0", "page=1", "page=2", "page=0"])
    }

    @Test("a comment deleted between pages is left out, and the one it moved onto a page already read is kept")
    func commentDeletedWhilePaging() async throws {
        let token = UUID().uuidString
        let function = MoodleAssignmentService.commentsFunction
        let remaining = Array((1...25).reversed()).filter { $0 != 20 }
        Self.answer(Self.commentsPage(Array((11...25).reversed()), count: 25), function: function, token: token)
        Self.answer(Self.commentsPage(Array(remaining.dropFirst(15)), count: 24), function: function, token: token)
        Self.answer(Self.commentsPage(Array(remaining.prefix(15)), count: 24), function: function, token: token)
        Self.answer(Self.commentsPage(Array(remaining.dropFirst(15)), count: 24), function: function, token: token)

        let comments = try await MoodleAssignmentService.comments(
            cmid: 9101, submissionId: 5501, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(comments.map(\.id) == Array(remaining.reversed()))
        #expect(Self.pages(asked: token) == ["page=0", "page=1", "page=0", "page=1"])
    }

    @Test("a second comment deleted while the pages are read again fails the read, keeping what the page showed")
    func commentsDeletedTwiceWhilePaging() async throws {
        let token = UUID().uuidString
        let function = MoodleAssignmentService.commentsFunction
        let remaining = Array((1...25).reversed()).filter { $0 != 20 }
        let fewer = remaining.filter { $0 != 5 }
        Self.answer(Self.commentsPage(Array((11...25).reversed()), count: 25), function: function, token: token)
        Self.answer(Self.commentsPage(Array(remaining.dropFirst(15)), count: 24), function: function, token: token)
        Self.answer(Self.commentsPage(Array(remaining.prefix(15)), count: 24), function: function, token: token)
        Self.answer(Self.commentsPage(Array(fewer.dropFirst(15)), count: 23), function: function, token: token)

        await #expect(throws: MoodleWebserviceError.self) {
            try await MoodleAssignmentService.comments(
                cmid: 9101, submissionId: 5501, token: token, session: Self.session(), siteURL: Self.site
            )
        }
        #expect(Self.pages(asked: token) == ["page=0", "page=1", "page=0", "page=1"])
    }

    @Test("a site that answers every page with the first stops the paging at the second")
    func pageIgnored() async throws {
        let token = UUID().uuidString
        for _ in 0...MoodleAssignmentService.commentPageLimit {
            Self.answer(Self.commentsPage(Array((1...15).reversed()), count: 40),
                        function: MoodleAssignmentService.commentsFunction, token: token)
        }

        let comments = try await MoodleAssignmentService.comments(
            cmid: 9101, submissionId: 5501, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(comments.map(\.id) == Array(1...15))
        #expect(Self.pages(asked: token) == ["page=0", "page=1", "page=0"])
    }

    @Test("a total Moodle never reaches stops the paging at the limit")
    func commentPageLimit() async throws {
        let token = UUID().uuidString
        let limit = MoodleAssignmentService.commentPageLimit
        for page in 0...limit + 1 {
            Self.answer(Self.commentsPage([1000 - page], count: 500),
                        function: MoodleAssignmentService.commentsFunction, token: token)
        }

        _ = try await MoodleAssignmentService.comments(
            cmid: 9101, submissionId: 5501, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(Self.pages(asked: token) == (0..<limit).map { "page=\($0)" } + ["page=0"])
    }

    @Test("the account's groups on a course come by id, with their names as text")
    func groups() async throws {
        let token = UUID().uuidString
        Self.answer(#"""
        {"groups": [
          {"id": 31, "name": "Group 3 &amp; friends", "description": "", "descriptionformat": 1, "idnumber": "",
           "courseid": 20119},
          {"id": 32, "name": "Lab B", "description": "<p>Thursday</p>", "descriptionformat": 1, "idnumber": "LB",
           "courseid": 20119}
        ], "warnings": []}
        """#, function: MoodleAssignmentService.groupsFunction, token: token)

        let groups = try await MoodleAssignmentService.groups(
            courseId: 20119, userId: 42, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(try Self.body(of: MoodleAssignmentService.groupsFunction, token: token) == "courseid=20119&userid=42")
        #expect(groups == [31: "Group 3 & friends", 32: "Lab B"])
    }
}
