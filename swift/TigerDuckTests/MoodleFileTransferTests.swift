import Foundation
import Testing
@testable import TigerDuck

@Suite(.serialized)
struct MoodleFileTransferTests {
    private static let site = URL(string: "https://moodle2.ntust.edu.tw")!
    private static let key = "0123456789abcdef0123456789abcdef"

    @Test("a file takes the private access key under tokenpluginfile, keeping its path and parameters")
    func accessKeyPath() throws {
        let file = try #require(URL(string: "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/31/mod_resource/content/2/%E8%AA%B2%E7%A8%8B.pdf?forcedownload=1"))
        let siteFile = try #require(URL(string: "https://moodle2.ntust.edu.tw/pluginfile.php/123/mod_forum/attachment/7001/scope.pdf?token=old"))

        #expect(MoodleFileTransfer.downloadURL(for: file, accessKey: Self.key, token: "t0k3n", siteURL: Self.site)?.absoluteString
            == "https://moodle2.ntust.edu.tw/tokenpluginfile.php/\(Self.key)/31/mod_resource/content/2/%E8%AA%B2%E7%A8%8B.pdf?forcedownload=1")
        #expect(MoodleFileTransfer.downloadURL(for: siteFile, accessKey: Self.key, token: "t0k3n", siteURL: Self.site)?.absoluteString
            == "https://moodle2.ntust.edu.tw/tokenpluginfile.php/\(Self.key)/123/mod_forum/attachment/7001/scope.pdf")
    }

    @Test("without a key the file goes through the web service path with the token")
    func tokenFallback() throws {
        let siteFile = try #require(URL(string: "https://moodle2.ntust.edu.tw/pluginfile.php/123/mod_forum/attachment/7001/scope.pdf"))

        #expect(MoodleFileTransfer.downloadURL(for: siteFile, accessKey: nil, token: "t0k3n", siteURL: Self.site)?.absoluteString
            == "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/123/mod_forum/attachment/7001/scope.pdf?token=t0k3n")
        #expect(MoodleFileTransfer.downloadURL(for: siteFile, accessKey: "", token: "t0k3n", siteURL: Self.site)?.query == "token=t0k3n")
    }

    @Test("no key goes to another host, over plain HTTP or to a page that is not a file", arguments: [
        "https://evil.example/webservice/pluginfile.php/31/mod_resource/content/2/a.pdf",
        "http://moodle2.ntust.edu.tw/webservice/pluginfile.php/31/mod_resource/content/2/a.pdf",
        "https://moodle2.ntust.edu.tw/mod/resource/view.php?id=9101",
        "https://moodle2.ntust.edu.tw/pluginfile.php?file=/31/mod_resource/content/2/a.pdf",
    ])
    func refusesOtherURLs(_ url: String) throws {
        let file = try #require(URL(string: url))
        #expect(MoodleFileTransfer.downloadURL(for: file, accessKey: Self.key, token: "t0k3n", siteURL: Self.site) == nil)
    }

    private static func response(_ status: Int = 200, type: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: site, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: type.map { ["Content-Type": $0] } ?? [:]
        )!
    }

    private static func body(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test("a reply of the file's own type passes, its parameters and case aside")
    func matchingType() throws {
        let file = try Self.body("%PDF")
        defer { try? FileManager.default.removeItem(at: file) }

        try MoodleFileTransfer.check(Self.response(type: "Application/PDF; name=a.pdf"), at: file, mimeType: "application/pdf")
        try MoodleFileTransfer.check(Self.response(type: "text/plain; charset=utf-8"), at: file, mimeType: "text/plain")
    }

    @Test("a page standing in for the file fails, and so does an error status")
    func otherTypeFails() throws {
        let file = try Self.body("<html>Sign in</html>")
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: MoodleWebserviceError.malformedResponse(detail: "text/html")) {
            try MoodleFileTransfer.check(Self.response(type: "text/html; charset=utf-8"), at: file, mimeType: "application/pdf")
        }
        #expect(throws: MoodleWebserviceError.httpStatus(code: 404)) {
            try MoodleFileTransfer.check(Self.response(404, type: "application/pdf"), at: file, mimeType: "application/pdf")
        }
    }

    @Test("a file of a type Moodle does not know passes as any type but a page or a web service error")
    func unknownType() throws {
        let file = try Self.body("Rar!")
        let page = try Self.body("<html>Sign in</html>")
        let error = try Self.body(#"{"error": "Invalid token", "errorcode": "invalidtoken"}"#)
        defer {
            for url in [file, page, error] { try? FileManager.default.removeItem(at: url) }
        }

        #expect(throws: Never.self) {
            try MoodleFileTransfer.check(Self.response(type: "application/octet-stream"), at: file, mimeType: "document/unknown")
        }
        #expect(throws: Never.self) {
            try MoodleFileTransfer.check(Self.response(type: "application/x-rar-compressed"), at: file, mimeType: "Document/Unknown")
        }
        #expect(throws: MoodleWebserviceError.malformedResponse(detail: "text/html")) {
            try MoodleFileTransfer.check(Self.response(type: "text/html; charset=utf-8"), at: page, mimeType: "document/unknown")
        }
        #expect(throws: MoodleWebserviceError.invalidToken) {
            try MoodleFileTransfer.check(Self.response(type: "application/json"), at: error, mimeType: "document/unknown")
        }
    }

    @Test("a file listed without a type passes as any type but a page", arguments: [nil, ""] as [String?])
    func unlistedType(_ mimeType: String?) throws {
        let file = try Self.body("%PDF-1.7")
        let page = try Self.body("<html>Sign in</html>")
        defer {
            for url in [file, page] { try? FileManager.default.removeItem(at: url) }
        }

        #expect(throws: Never.self) {
            try MoodleFileTransfer.check(Self.response(type: "application/pdf"), at: file, mimeType: mimeType)
        }
        #expect(throws: MoodleWebserviceError.malformedResponse(detail: "text/html")) {
            try MoodleFileTransfer.check(Self.response(type: "text/html; charset=utf-8"), at: page, mimeType: mimeType)
        }
    }

    @Test("a web service error in place of the file throws its own case, so a stale token renews")
    func webServiceError() throws {
        let file = try Self.body(#"{"error": "Invalid token", "errorcode": "invalidtoken"}"#)
        defer { try? FileManager.default.removeItem(at: file) }

        #expect(throws: MoodleWebserviceError.invalidToken) {
            try MoodleFileTransfer.check(Self.response(type: "application/json"), at: file, mimeType: "application/pdf")
        }
    }

    @Test("a JSON file is kept, but a web service error in its place throws its case all the same")
    func jsonFile() throws {
        let error = try Self.body(#"{"error": "Invalid token", "errorcode": "invalidtoken"}"#)
        let file = try Self.body(#"[{"week": 1, "topic": "HTTP"}]"#)
        defer {
            try? FileManager.default.removeItem(at: error)
            try? FileManager.default.removeItem(at: file)
        }

        #expect(throws: MoodleWebserviceError.invalidToken) {
            try MoodleFileTransfer.check(Self.response(type: "application/json"), at: error, mimeType: "application/json")
        }
        try MoodleFileTransfer.check(Self.response(type: "application/json"), at: file, mimeType: "application/json")
    }

    @Test("a download lands in a temporary file with the reply's bytes")
    func fetch() async throws {
        let url = try #require(URL(string: "https://moodle-stub.invalid/tokenpluginfile.php/\(Self.key)/\(UUID().uuidString)/a.pdf"))
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data("%PDF-1.7".utf8), headerFields: ["Content-Type": "application/pdf"]),
            for: url
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]

        let copy = try await MoodleFileTransfer.fetch(
            url, mimeType: "application/pdf", expectedSize: 8, session: URLSession(configuration: config)
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: copy) }

        #expect(try Data(contentsOf: copy) == Data("%PDF-1.7".utf8))
        #expect(SettingsAPIStub.requests(for: url).count == 1)
    }

    @Test("a download whose reply is not the file leaves no temporary file behind")
    func fetchFailureCleansUp() async throws {
        let url = try #require(URL(string: "https://moodle-stub.invalid/tokenpluginfile.php/\(Self.key)/\(UUID().uuidString)/a.pdf"))
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data("<html></html>".utf8), headerFields: ["Content-Type": "text/html"]),
            for: url
        )
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let before = Self.temporaryDownloads()

        await #expect(throws: MoodleWebserviceError.malformedResponse(detail: "text/html")) {
            try await MoodleFileTransfer.fetch(
                url, mimeType: "application/pdf", expectedSize: 13, session: URLSession(configuration: config)
            ) { _ in }
        }
        #expect(Self.temporaryDownloads() == before)
    }

    private static func temporaryDownloads() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("MoodleDownload-") })
    }
}
