import Foundation
import Testing
@testable import TigerDuck

/// `core_course_get_courses_by_field` for a course's summary, against `SettingsAPIStub` on a site
/// that does not exist, so no request reaches Moodle, and the rule that leaves out a summary
/// with nothing of its own. The answers follow the shape Moodle 4.5 documents; every name in
/// them is made up.
struct MoodleCourseSummaryServiceTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    /// The URL a call posts to; the token keeps it unique to one test.
    private static func endpoint(token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(MoodleCourseSummaryService.coursesFunction)&wstoken=\(token)")!
    }

    private static func answer(_ body: String, token: String) {
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: endpoint(token: token))
    }

    static let course = #"""
    {"courses": [
      {"id": 20119, "fullname": "Computer Networks &amp; Lab", "displayname": "Computer Networks &amp; Lab",
       "shortname": "1141CS3105301 Networks", "categoryid": 12, "categoryname": "Computer Science",
       "sortorder": 10001,
       "summary": "<p dir=\"ltr\">Layers and protocols, from <strong>HTTP</strong> to TCP.</p><ul><li>Lab every two weeks</li></ul>",
       "summaryformat": 1, "summaryfiles": [], "overviewfiles": [], "showactivitydates": true,
       "showcompletionconditions": true, "contacts": [{"id": 3, "fullname": "Tiger Duck"}],
       "enrollmentmethods": ["manual"], "format": "weeks", "showgrades": 1, "newsitems": 5,
       "startdate": 1788192000, "enddate": 1803744000, "maxbytes": 0, "showreports": 0, "visible": 1,
       "groupmode": 0, "groupmodeforce": 0, "defaultgroupingid": 0, "enablecompletion": 1,
       "completionnotify": 0, "lang": "", "theme": "", "marker": 0, "filters": [],
       "courseformatoptions": []}
    ], "warnings": []}
    """#

    @Test("the summary asks for the one course by id, with the site's text filters on")
    func request() async throws {
        let token = UUID().uuidString
        Self.answer(Self.course, token: token)

        _ = try await MoodleCourseSummaryService.summary(courseId: 20119, token: token, session: Self.session(), siteURL: Self.site)

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint(token: token)).first)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "field=id&value=20119&moodlewssettingfilter=true")
    }

    @Test("a course decodes its summary as HTML and as one line of text, with its names as text")
    func decode() async throws {
        let token = UUID().uuidString
        Self.answer(Self.course, token: token)

        let summary = try await MoodleCourseSummaryService.summary(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(summary.html.hasPrefix("<p dir=\"ltr\">Layers and protocols"))
        #expect(summary.text == "Layers and protocols, from HTTP to TCP. Lab every two weeks")
        #expect(summary.names == ["Computer Networks & Lab", "Computer Networks & Lab", "1141CS3105301 Networks"])
    }

    @Test("a course Moodle does not list has no summary")
    func unlisted() async throws {
        let token = UUID().uuidString
        Self.answer(#"{"courses": [], "warnings": []}"#, token: token)

        let summary = try await MoodleCourseSummaryService.summary(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(summary == .empty)
    }

    // MARK: - What shows

    private static func summary(_ html: String, names: [String] = ["Computer Networks", "CN 2025"]) -> MoodleCourseSummary {
        MoodleCourseSummary(html: html, text: MoodleHTMLText.plainText(fromHTML: html), names: names)
    }

    private static let codes = ["1141CS3105301", "CS3105301"]

    @Test("a summary of its own shows, even one that names the course's code", arguments: [
        "<p>本課程介紹電腦網路的分層架構與常見協定。</p>",
        "<p>Layers and protocols.</p>",
        "<p>1141CS3105301 meets in TR-412.</p>",
    ])
    func showsOwnText(_ html: String) {
        #expect(Self.summary(html).isWorthShowing(besides: Self.codes))
    }

    @Test("a summary empty without its HTML, or with no letter or Han character, shows nothing", arguments: [
        "", "<p></p>", "<p>&nbsp;</p>", "<p><img src=\"https://moodle-stub.invalid/a.png\"></p>",
        "<p>2025 - 09 - 01</p>", "<p>—</p>", "<p>👍</p>",
    ])
    func hidesNothingToRead(_ html: String) {
        #expect(!Self.summary(html).isWorthShowing(besides: Self.codes))
    }

    @Test("a summary that only repeats a name or code of the course, ignoring case and spaces, shows nothing", arguments: [
        "<p>1141CS3105301</p>", "<p>1141 cs3105301</p>", "<p>CS3105301</p>",
        "<p>Computer Networks</p>", "<p>computernetworks</p>", "<p>CN&nbsp;2025</p>",
    ])
    func hidesARepeat(_ html: String) {
        #expect(!Self.summary(html).isWorthShowing(besides: Self.codes))
    }
}
