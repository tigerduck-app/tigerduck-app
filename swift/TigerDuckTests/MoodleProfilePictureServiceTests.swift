import Foundation
import Testing
@testable import TigerDuck

struct MoodleProfilePictureServiceTests {
    private static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return URLSession(configuration: config)
    }

    private static func update(site: URL, token: String) -> URL {
        URL(string: "\(site.absoluteString)/webservice/rest/server.php"
            + "?moodlewsrestformat=json&wsfunction=core_user_update_picture&wstoken=\(token)")!
    }

    @Test("the picture goes to a draft area in a multipart form holding the token, then that draft becomes the picture")
    func uploadThenUpdate() async throws {
        let site = URL(string: "https://moodle-\(UUID().uuidString.lowercased()).invalid")!
        let upload = site.appendingPathComponent("webservice/upload.php")
        let token = UUID().uuidString
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01])
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"[{"component":"user","filearea":"draft","itemid":987654,"filename":"picture.jpg"}]"#.utf8)), for: upload)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"success":true,"profileimageurl":"x","warnings":[]}"#.utf8)),
                                for: Self.update(site: site, token: token))

        try await MoodleProfilePictureService.update(jpeg: jpeg, token: token, session: Self.session(), siteURL: site,
                                                    boundary: "BOUNDARY")

        let sent = try #require(SettingsAPIStub.requests(for: upload).first)
        #expect(sent.httpMethod == "POST")
        #expect(sent.url?.query == nil)
        #expect(sent.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=BOUNDARY")
        let body = try #require(SettingsAPIStub.bodyData(from: sent))
        var expected = Data((
            "--BOUNDARY\r\nContent-Disposition: form-data; name=\"token\"\r\n\r\n\(token)\r\n"
            + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"filearea\"\r\n\r\ndraft\r\n"
            + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"itemid\"\r\n\r\n0\r\n"
            + "--BOUNDARY\r\nContent-Disposition: form-data; name=\"file\"; filename=\"picture.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\n"
        ).utf8)
        expected.append(jpeg)
        expected.append(Data("\r\n--BOUNDARY--\r\n".utf8))
        #expect(body == expected)

        let set = try #require(SettingsAPIStub.requests(for: Self.update(site: site, token: token)).first)
        #expect(SettingsAPIStub.bodyData(from: set).flatMap { String(data: $0, encoding: .utf8) } == "draftitemid=987654&delete=0")
    }

    @Test("an upload Moodle refuses throws its error and sets nothing")
    func refusedUpload() async throws {
        let site = URL(string: "https://moodle-\(UUID().uuidString.lowercased()).invalid")!
        let upload = site.appendingPathComponent("webservice/upload.php")
        let token = UUID().uuidString
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"error":"Invalid token","errorcode":"invalidtoken"}"#.utf8)),
                                for: upload)

        await #expect(throws: MoodleWebserviceError.invalidToken) {
            try await MoodleProfilePictureService.update(jpeg: Data([1]), token: token, session: Self.session(), siteURL: site)
        }
        #expect(SettingsAPIStub.requests(for: Self.update(site: site, token: token)).isEmpty)
    }

    @Test("a picture Moodle does not take throws")
    func notTaken() async throws {
        let site = URL(string: "https://moodle-\(UUID().uuidString.lowercased()).invalid")!
        let token = UUID().uuidString
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"[{"itemid":5}]"#.utf8)),
                                for: site.appendingPathComponent("webservice/upload.php"))
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"success":false,"warnings":[]}"#.utf8)),
                                for: Self.update(site: site, token: token))

        await #expect(throws: MoodleWebserviceError.self) {
            try await MoodleProfilePictureService.update(jpeg: Data([1]), token: token, session: Self.session(), siteURL: site)
        }
    }
}
