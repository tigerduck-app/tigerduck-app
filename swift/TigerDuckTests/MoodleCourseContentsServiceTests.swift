import Foundation
import os
import Testing
@testable import TigerDuck

struct MoodleCourseContentsServiceTests {
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

    private static let fileBase = "https://moodle2.ntust.edu.tw/webservice/pluginfile.php"

    static let contents = #"""
    [
      {"id": 100, "name": "General", "visible": 1, "summary": "", "summaryformat": 1, "section": 0,
       "hiddenbynumsections": 0, "uservisible": true, "modules": [
        {"id": 9101, "url": "https://moodle2.ntust.edu.tw/mod/resource/view.php?id=9101", "name": "Syllabus",
         "instance": 301, "contextid": 31, "visible": 1, "uservisible": true, "modname": "resource",
         "modplural": "Files", "indent": 0, "noviewlink": false, "completion": 0, "dates": [],
         "contents": [
           {"type": "file", "filename": "syllabus.pdf", "filepath": "/", "filesize": 204800,
            "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/31/mod_resource/content/2/syllabus.pdf?forcedownload=1",
            "timecreated": 1788000000, "timemodified": 1788100000, "sortorder": 1, "mimetype": "application/pdf",
            "isexternalfile": false, "userid": 3, "author": "Teacher", "license": "unknown"},
           {"type": "file", "filename": "logo.png", "filepath": "/", "filesize": 1024,
            "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/31/mod_resource/content/2/logo.png?forcedownload=1",
            "timecreated": 1788000000, "timemodified": 1788000000, "sortorder": 0, "mimetype": "image/png",
            "isexternalfile": false}
         ]},
        {"id": 9102, "name": "Welcome", "instance": 302, "visible": 1, "uservisible": true, "modname": "label"}
      ]},
      {"id": 101, "name": "Week 1 &amp; 2", "visible": 1, "summary": "", "section": 1, "uservisible": true, "modules": [
        {"id": 9201, "url": "https://moodle2.ntust.edu.tw/mod/url/view.php?id=9201", "name": "HTTP reading",
         "instance": 401, "visible": 1, "uservisible": true, "modname": "url",
         "contents": [
           {"type": "url", "filename": "HTTP reading", "filepath": null, "filesize": 0,
            "fileurl": "https://developer.mozilla.org/en-US/docs/Web/HTTP", "timecreated": null,
            "timemodified": 1788200000, "sortorder": null, "userid": null, "author": null, "license": null}
         ]},
        {"id": 9202, "name": "Odd link", "instance": 402, "visible": 1, "uservisible": true, "modname": "url",
         "contents": [{"type": "url", "filename": "Odd link", "filesize": 0, "fileurl": "javascript:alert(1)"}]},
        {"id": 9203, "name": "Homework 1", "instance": 403, "visible": 1, "uservisible": true, "modname": "assign"},
        {"id": 9204, "name": "Q&A", "instance": 404, "visible": 1, "uservisible": true, "modname": "forum"}
      ]},
      {"id": 102, "name": "Week 3", "visible": 1, "summary": "", "section": 2, "uservisible": true, "modules": [
        {"id": 9301, "name": "Lab 1 &lt;files&gt;", "instance": 501, "visible": 1, "uservisible": true,
         "modname": "folder", "contents": [
           {"type": "file", "filename": "lab1-spec.pdf", "filepath": "/", "filesize": 1153434,
            "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/32/mod_folder/content/4/lab1-spec.pdf?forcedownload=1",
            "timemodified": 1788300000, "mimetype": "application/pdf"},
           {"type": "file", "filename": "starter.zip", "filepath": "/code/", "filesize": 2411724,
            "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/32/mod_folder/content/4/code/starter.zip?forcedownload=1",
            "timemodified": 1788300100, "mimetype": "application/zip"},
           {"type": "file", "filename": "format.docx", "filepath": "/", "filesize": 49152,
            "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/32/mod_folder/content/4/format.docx?forcedownload=1",
            "timemodified": 1788300200,
            "mimetype": "application/vnd.openxmlformats-officedocument.wordprocessingml.document"}
         ]},
        {"id": 9302, "name": "Locked slides", "instance": 502, "visible": 1, "uservisible": false, "modname": "resource"},
        {"id": 9303, "name": "Empty folder", "instance": 503, "visible": 1, "uservisible": true, "modname": "folder",
         "contents": []},
        {"id": 9304, "name": "Gone file", "instance": 504, "visible": 1, "uservisible": true, "modname": "resource"}
      ]},
      {"id": 103, "name": "Week 4", "visible": 1, "summary": "", "section": 3, "uservisible": true, "modules": [
        {"id": 9401, "name": "Note", "instance": 601, "visible": 1, "uservisible": true, "modname": "label"}
      ]},
      {"id": 104, "name": "Restricted", "visible": 1, "summary": "", "section": 4, "uservisible": false, "modules": [
        {"id": 9501, "name": "Answers", "instance": 701, "visible": 1, "uservisible": true, "modname": "resource",
         "contents": [{"type": "file", "filename": "answers.pdf", "filepath": "/", "filesize": 10,
           "fileurl": "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/35/mod_resource/content/1/answers.pdf",
           "timemodified": 1788400000, "mimetype": "application/pdf"}]}
      ]}
    ]
    """#

    @Test("materials ask for the course and keep Moodle's section order")
    func materialsRequest() async throws {
        let token = UUID().uuidString
        Self.answer(Self.contents, function: MoodleCourseContentsService.contentsFunction, token: token)

        let materials = try await MoodleCourseContentsService.materials(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        let request = try #require(SettingsAPIStub.requests(
            for: Self.endpoint(MoodleCourseContentsService.contentsFunction, token: token)
        ).first)
        #expect(SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) } == "wstoken=\(token)&courseid=20119")
        #expect(materials.sections.map(\.id) == [100, 101, 102])
        #expect(materials.sections.map(\.name) == ["General", "Week 1 & 2", "Week 3"])
    }

    @Test("only files, folders and links an account can open are kept, and a section with none of them is not")
    func materialsKeepWhatOpens() async throws {
        let token = UUID().uuidString
        Self.answer(Self.contents, function: MoodleCourseContentsService.contentsFunction, token: token)

        let materials = try await MoodleCourseContentsService.materials(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(materials.sections.map { $0.materials.map(\.id) } == [[9101], [9201], [9301]])
        let syllabus = try #require(materials.sections.first?.materials.first)
        #expect(syllabus.name == "Syllabus")
        #expect(syllabus.module == "resource")
        #expect(syllabus.instance == 301)
        #expect(syllabus.content == .file(MoodleFile(
            name: "syllabus.pdf", size: 204_800,
            url: "\(Self.fileBase)/31/mod_resource/content/2/syllabus.pdf?forcedownload=1",
            mimeType: "application/pdf", modified: Date(timeIntervalSince1970: 1_788_100_000), path: "/"
        )))
        let link = try #require(materials.sections[1].materials.first)
        #expect(link.content == .link(URL(string: "https://developer.mozilla.org/en-US/docs/Web/HTTP")!))
        let folder = try #require(materials.sections[2].materials.first)
        #expect(folder.name == "Lab 1 <files>")
        guard case .folder(let files) = folder.content else {
            Issue.record("a folder decodes as one")
            return
        }
        #expect(files.map(\.name) == ["lab1-spec.pdf", "starter.zip", "format.docx"])
        #expect(files.map(\.path) == ["/", "/code/", "/"])
    }

    @Test("the count is files and links, with each file of a folder on its own")
    func materialsCount() async throws {
        let token = UUID().uuidString
        Self.answer(Self.contents, function: MoodleCourseContentsService.contentsFunction, token: token)

        let materials = try await MoodleCourseContentsService.materials(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(materials.count == 5)
        #expect(MoodleCourseMaterials(sections: []).count == 0)
    }

    @Test("site info keeps the private access key file URLs take, and none when it is missing or empty")
    func siteInfoAccessKey() async throws {
        let token = UUID().uuidString
        Self.answer(
            #"{"sitename": "Moodle", "userid": 42, "userprivateaccesskey": "0123456789abcdef0123456789abcdef"}"#,
            function: "core_webservice_get_site_info", token: token
        )
        let bare = UUID().uuidString
        Self.answer(#"{"sitename": "Moodle", "userid": 7}"#, function: "core_webservice_get_site_info", token: bare)
        let empty = UUID().uuidString
        Self.answer(
            #"{"sitename": "Moodle", "userid": 7, "userprivateaccesskey": ""}"#,
            function: "core_webservice_get_site_info", token: empty
        )

        let info = try await MoodleSiteInfoService.fetchSiteInfo(token: token, session: Self.session(), siteURL: Self.site)
        #expect(info.privateAccessKey == "0123456789abcdef0123456789abcdef")
        let bareInfo = try await MoodleSiteInfoService.fetchSiteInfo(token: bare, session: Self.session(), siteURL: Self.site)
        #expect(bareInfo.privateAccessKey == nil)
        let emptyInfo = try await MoodleSiteInfoService.fetchSiteInfo(token: empty, session: Self.session(), siteURL: Self.site)
        #expect(emptyInfo.privateAccessKey == nil)
    }

    @Test("a file's view goes out only under the account that opened it, after the token wait")
    func viewWaitsForTheTokenUnderItsAccount() async throws {
        let token = UUID().uuidString
        let endpoint = Self.endpoint("mod_resource_view_resource", token: token)
        Self.answer(#"{"status":true,"warnings":[]}"#, function: "mod_resource_view_resource", token: token)
        let material = MoodleMaterial(
            id: 9101, instance: 301, module: "resource", name: "Syllabus",
            content: .link(URL(string: "https://moodle-stub.invalid/mod/resource/view.php?id=9101")!)
        )
        let current = OSAllocatedUnfairLock(initialState: true)
        let gate = ManualSleeper()
        let renewing = MoodleWebserviceClient.TokenSource(
            stored: { nil },
            renew: { _ in
                await gate.sleep(for: .seconds(1))
                return token
            }
        )
        let event = Task {
            try await MoodleCourseAPI.logMaterialView(
                material, isCurrent: { current.withLock { $0 } }, tokens: renewing, session: Self.session(), siteURL: Self.site
            )
        }
        try await gate.waitUntilArmed()
        current.withLock { $0 = false }
        await gate.fire()

        await #expect(throws: CancellationError.self) { try await event.value }
        #expect(SettingsAPIStub.requests(for: endpoint).isEmpty)

        try await MoodleCourseAPI.logMaterialView(
            material, isCurrent: { true }, tokens: .init(stored: { token }, renew: { _ in token }),
            session: Self.session(), siteURL: Self.site
        )
        #expect(SettingsAPIStub.requests(for: endpoint).count == 1)
    }
}
