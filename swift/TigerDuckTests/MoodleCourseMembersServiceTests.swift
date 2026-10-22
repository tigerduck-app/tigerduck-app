import Foundation
import Testing
@testable import TigerDuck

struct MoodleCourseMembersServiceTests {
    private static let site = URL(string: "https://moodle-stub.invalid")!

    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    private static func endpoint(token: String) -> URL {
        URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=\(MoodleCourseMembersService.membersFunction)&wstoken=\(token)")!
    }

    static let members = #"""
    [
      {"id": 3, "fullname": "Tiger Teacher", "email": "teacher@example.edu.tw",
       "profileimageurl": "https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f1?rev=5",
       "description": "<p dir=\"ltr\">Office hours: <strong>Tue</strong> 10:00</p>", "descriptionformat": 1,
       "interests": "networks, QUIC ,",
       "roles": [{"roleid": 3, "name": "", "shortname": "editingteacher", "sortorder": 3}],
       "groups": [],
       "customfields": [
         {"type": "text", "value": "TR-412", "name": "Office &amp; lab", "shortname": "office"},
         {"type": "checkbox", "value": "1", "name": "Agrees", "shortname": "agree"},
         {"type": "datetime", "value": "1790000000", "name": "Born", "shortname": "born"},
         {"type": "menu", "value": "", "name": "Year", "shortname": "year"}
       ]},
      {"id": 42, "fullname": "B11399001 @ Tiger Duck", "idnumber": "B11399001",
       "email": "b11399001@example.edu.tw",
       "profileimageurl": "https://moodle-stub.invalid/theme/image.php/moove/core/1/u/f1",
       "roles": [{"roleid": 5, "name": "", "shortname": "student", "sortorder": 5}],
       "groups": [{"id": 9, "name": "Group 3 &amp; 4", "description": "", "descriptionformat": 1}]},
      {"id": 77, "fullname": "B11399002 @ Duck Tiger", "idnumber": " ",
       "roles": [{"roleid": 5, "name": "", "shortname": "student", "sortorder": 5}]}
    ]
    """#

    @Test("members ask for the course and only the fields the screens show")
    func request() async throws {
        let token = UUID().uuidString
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(Self.members.utf8)), for: Self.endpoint(token: token))

        _ = try await MoodleCourseMembersService.members(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        let request = try #require(SettingsAPIStub.requests(for: Self.endpoint(token: token)).first)
        let body = SettingsAPIStub.bodyData(from: request).flatMap { String(data: $0, encoding: .utf8) }
        #expect(body == "courseid=20119&options%5B0%5D%5Bname%5D=userfields&options%5B0%5D%5Bvalue%5D="
            + "id%2Cfullname%2Cidnumber%2Cemail%2Cgroups%2Croles%2Cprofileimageurl%2Cdescription"
            + "%2Cinterests%2Ccustomfields")
    }

    @Test("a member decodes as text, keeps only their own picture, and drops what Moodle leaves empty")
    func decode() async throws {
        let token = UUID().uuidString
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(Self.members.utf8)), for: Self.endpoint(token: token))

        let members = try await MoodleCourseMembersService.members(
            courseId: 20119, token: token, session: Self.session(), siteURL: Self.site
        )

        #expect(members.map(\.id) == [3, 42, 77])
        let teacher = members[0]
        #expect(teacher.fullName == "Tiger Teacher")
        #expect(teacher.idNumber == nil)
        #expect(teacher.email == "teacher@example.edu.tw")
        #expect(teacher.roles == [MoodleMember.Role(shortName: "editingteacher", name: "", sortOrder: 3)])
        #expect(teacher.pictureURL == URL(string: "https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f1?rev=5"))
        #expect(teacher.description == "Office hours: Tue 10:00")
        #expect(teacher.interests == ["networks", "QUIC"])
        #expect(teacher.fields == [MoodleMember.Field(name: "Office & lab", value: "TR-412")])

        let student = members[1]
        #expect(student.idNumber == "B11399001")
        #expect(student.groups == ["Group 3 & 4"])
        #expect(student.pictureURL == nil)

        let bare = members[2]
        #expect(bare.idNumber == nil)
        #expect(bare.email == nil)
        #expect(bare.groups.isEmpty)
        #expect(bare.description.isEmpty)
        #expect(bare.interests.isEmpty)
        #expect(bare.fields.isEmpty)
    }

    @Test("only a picture the member uploaded to this site is theirs; Moodle's default and others' are not")
    func ownPicture() throws {
        let own = [
            "https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f1?rev=5",
            "https://MOODLE-STUB.invalid/webservice/pluginfile.php/88/user/icon/moove/f2?rev=5",
        ]
        let notOwn = [
            "https://moodle-stub.invalid/theme/image.php/moove/core/1/u/f1",
            "https://moodle-stub.invalid/pluginfile.php/88/mod_forum/attachment/1/a.png",
            "https://elsewhere.invalid/pluginfile.php/88/user/icon/moove/f1",
            "http://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f1",
            "https://secure.gravatar.com/avatar/0123?s=100",
        ]
        for url in own {
            #expect(MoodleCourseMembersService.isOwnPicture(try #require(URL(string: url)), siteURL: Self.site), "\(url)")
        }
        for url in notOwn {
            #expect(!MoodleCourseMembersService.isOwnPicture(try #require(URL(string: url)), siteURL: Self.site), "\(url)")
        }
    }

    @Test("the 512 px picture is an f1 picture's f3 under the same path and revision, and no other size has one")
    func largePicture() throws {
        let cases: [(picture: String, large: String?)] = [
            ("https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f1?rev=5",
             "https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f3?rev=5"),
            ("https://moodle-stub.invalid/webservice/pluginfile.php/88/user/icon/moove/f1",
             "https://moodle-stub.invalid/webservice/pluginfile.php/88/user/icon/moove/f3"),
            ("https://moodle-stub.invalid/pluginfile.php/88/user/icon/f1?rev=5",
             "https://moodle-stub.invalid/pluginfile.php/88/user/icon/f3?rev=5"),
            ("https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f2?rev=5", nil),
            ("https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f3?rev=5", nil),
        ]
        for (picture, large) in cases {
            let derived = MoodleCourseMembersService.largePicture(try #require(URL(string: picture)))
            #expect(derived?.absoluteString == large, "\(picture)")
            if let derived {
                #expect(MoodleCourseMembersService.isOwnPicture(derived, siteURL: Self.site), "\(picture)")
            }
        }
    }

    @Test("a picture downloads under tokenpluginfile; its answer counts only as an image, and a page standing in throws")
    func pictureAnswer() async throws {
        let picture = try #require(URL(string: "https://moodle-stub.invalid/pluginfile.php/88/user/icon/moove/f1?rev=5"))
        let key = UUID().uuidString
        let download = try #require(MoodleFileTransfer.downloadURL(for: picture, accessKey: key, token: "t0k", siteURL: Self.site))
        #expect(download.path.hasPrefix("/tokenpluginfile.php/\(key)/"))
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: png, headerFields: ["Content-Type": "image/png"]), for: download)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("<html></html>".utf8), headerFields: ["Content-Type": "text/html"]), for: download)

        let data = try await MoodleCourseMembersService.picture(
            picture, accessKey: key, token: "t0k", session: Self.session(), siteURL: Self.site
        )
        #expect(data == png)
        await #expect(throws: MoodleWebserviceError.self) {
            try await MoodleCourseMembersService.picture(picture, accessKey: key, token: "t0k", session: Self.session(), siteURL: Self.site)
        }
    }

    @Test("site info keeps the private access key that file URLs take, none when Moodle sends none")
    func privateAccessKey() async throws {
        let token = UUID().uuidString
        let bare = UUID().uuidString
        let info = URL(string: "https://moodle-stub.invalid/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=core_webservice_get_site_info&wstoken=")!
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"userid": 42, "userprivateaccesskey": "k3y"}"#.utf8)),
            for: URL(string: info.absoluteString + token)!
        )
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"userid": 42, "userprivateaccesskey": ""}"#.utf8)),
            for: URL(string: info.absoluteString + bare)!
        )

        #expect(try await MoodleSiteInfoService.fetchSiteInfo(token: token, session: Self.session(), siteURL: Self.site)
            .privateAccessKey == "k3y")
        #expect(try await MoodleSiteInfoService.fetchSiteInfo(token: bare, session: Self.session(), siteURL: Self.site)
            .privateAccessKey == nil)
    }
}
