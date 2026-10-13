import Foundation
import Testing
@testable import TigerDuck

/// `gradereport_user_get_grade_items` against `SettingsAPIStub` on a site that does not exist, so
/// no request reaches Moodle. The answers follow the shape Moodle 4.5 documents for the function;
/// every name and grade in them is made up.
struct MoodleGradeServiceTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    /// The URL the call posts to; the token keeps it unique to one test.
    private static func endpoint(token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(MoodleGradeService.gradeItemsFunction)&wstoken=\(token)")!
    }

    private static func answer(_ body: String, token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: endpoint(token: token))
    }

    private static func gradeItems(token: String, userId: Int = 42) async throws -> [MoodleGradeItem] {
        try await MoodleGradeService.gradeItems(
            courseId: 20119, userId: userId, token: token, session: session(), siteURL: site
        )
    }

    static let gradebook = #"""
    {"usergrades": [{"courseid": 20119, "courseidnumber": "1141CS3001301", "userid": 42,
      "userfullname": "B11399001 @ Tiger Duck", "useridnumber": "B11399001", "maxdepth": 2,
      "gradeitems": [
        {"id": 3001, "itemname": "Lab 1 &amp; sockets", "itemtype": "mod", "itemmodule": "assign",
         "iteminstance": 801, "itemnumber": 0, "idnumber": "", "categoryid": 70, "outcomeid": null,
         "scaleid": null, "locked": false, "cmid": 9101, "weightraw": 0.25, "weightformatted": "25.00 %",
         "graderaw": 92, "gradedatesubmitted": 1792030000, "gradedategraded": 1792040000,
         "gradehiddenbydate": false, "gradeneedsupdate": false, "gradeishidden": false,
         "gradeislocked": false, "gradeisoverridden": false, "gradeformatted": "92.00", "grademin": 0,
         "grademax": 100, "rangeformatted": "0&ndash;100", "percentageformatted": "92.00 %",
         "feedback": "<p>Clear structure, <strong>good</strong> tests.</p>", "feedbackformat": 1},
        {"id": 3002, "itemname": "Quiz 1", "itemtype": "mod", "itemmodule": "quiz", "iteminstance": 55,
         "itemnumber": 0, "idnumber": "", "categoryid": 70, "outcomeid": null, "scaleid": null,
         "cmid": 9102, "graderaw": null, "gradedatesubmitted": null, "gradedategraded": null,
         "gradehiddenbydate": false, "gradeneedsupdate": false, "gradeishidden": false,
         "gradeislocked": null, "gradeisoverridden": null, "gradeformatted": "-", "grademin": 0,
         "grademax": 10, "rangeformatted": "0&ndash;10", "percentageformatted": "-", "feedback": "",
         "feedbackformat": 0},
        {"id": 3003, "itemname": "Midterm", "itemtype": "manual", "itemmodule": null, "iteminstance": null,
         "itemnumber": 0, "idnumber": "", "categoryid": 70, "outcomeid": null, "scaleid": null,
         "graderaw": 7.5, "gradehiddenbydate": false, "gradeneedsupdate": false, "gradeishidden": false,
         "gradeformatted": "7.50", "grademin": 0, "grademax": 10, "feedback": "", "feedbackformat": 0},
        {"id": 3004, "itemname": "Lab 2", "itemtype": "mod", "itemmodule": "assign", "iteminstance": 802,
         "itemnumber": 0, "idnumber": "", "categoryid": 70, "outcomeid": null, "scaleid": null,
         "cmid": 9103, "graderaw": null, "gradedatesubmitted": 1792050000, "gradehiddenbydate": true,
         "gradeneedsupdate": false, "gradeishidden": true, "gradeformatted": "Submitted on 13 October 2026",
         "grademin": 0, "grademax": 100, "feedback": "", "feedbackformat": 0},
        {"id": 3005, "itemname": null, "itemtype": "category", "itemmodule": null, "iteminstance": 70,
         "itemnumber": null, "idnumber": null, "categoryid": null, "outcomeid": null, "scaleid": null,
         "graderaw": 92, "gradehiddenbydate": false, "gradeneedsupdate": false, "gradeishidden": false,
         "gradeformatted": "92.00", "grademin": 0, "grademax": 100},
        {"id": 3000, "itemname": null, "itemtype": "course", "itemmodule": null, "iteminstance": 1,
         "itemnumber": null, "idnumber": null, "categoryid": null, "outcomeid": null, "scaleid": null,
         "graderaw": 87.5, "gradehiddenbydate": false, "gradeneedsupdate": false, "gradeishidden": false,
         "gradeformatted": "87.50", "grademin": 0, "grademax": 100}
      ]}],
     "warnings": []}
    """#

    @Test("the call asks for one course's grades for the signed-in user")
    func request() async throws {
        let token = UUID().uuidString
        Self.answer(Self.gradebook, token: token)

        _ = try await Self.gradeItems(token: token)

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint(token: token)).first)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "courseid=20119&userid=42")
    }

    @Test("items decode in the gradebook's order, with no grade for one ungraded or kept from the student")
    func decode() async throws {
        let token = UUID().uuidString
        Self.answer(Self.gradebook, token: token)

        let items = try await Self.gradeItems(token: token)

        #expect(items.map(\.id) == [3001, 3002, 3003, 3004, 3005, 3000])
        #expect(items[0] == MoodleGradeItem(
            id: 3001, name: "Lab 1 & sockets", type: "mod", module: "assign", cmid: 9101, grade: "92.00",
            maxGrade: 100, isHidden: false, feedback: "Clear structure, **good** tests."
        ))
        #expect(items[1].grade == nil)
        #expect(items[1].maxGrade == 10)
        #expect(items[2] == MoodleGradeItem(
            id: 3003, name: "Midterm", type: "manual", module: nil, cmid: nil, grade: "7.50",
            maxGrade: 10, isHidden: false, feedback: ""
        ))
        #expect(items[3].grade == nil)
        #expect(items[3].isHidden)
        #expect(items[4].isCategoryTotal && items[4].name.isEmpty)
        #expect(items[5].isCourseTotal && items[5].grade == "87.50")
    }

    @Test("a course that keeps its grade report from students has no grades, which is not a failure")
    func withheldReport() async throws {
        for code in ["nopermissiontoviewgrades", "nopermissions"] {
            let token = UUID().uuidString
            Self.answer(
                #"{"exception": "moodle_exception", "errorcode": "\#(code)", "message": "No permission"}"#,
                token: token
            )
            #expect(try await Self.gradeItems(token: token).isEmpty)
        }
    }

    @Test("any other Moodle error still fails the fetch")
    func otherErrorsFail() async {
        let token = UUID().uuidString
        Self.answer(#"{"exception": "dml_missing_record_exception", "errorcode": "invalidrecord"}"#, token: token)

        await #expect(throws: MoodleWebserviceError.malformedResponse(detail: "invalidrecord")) {
            try await Self.gradeItems(token: token)
        }
    }

    @Test("an answer about another user is not taken for the signed-in one")
    func otherUser() async throws {
        let token = UUID().uuidString
        Self.answer(Self.gradebook, token: token)

        #expect(try await Self.gradeItems(token: token, userId: 7).isEmpty)
    }
}
