import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ConditionalGetTests {
    private static func backend(_ base: URL) -> BackendClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return BackendClient(baseURL: { base }, session: URLSession(configuration: config))
    }

    private static func feed(_ base: URL) throws -> URL {
        try #require(URL(string: base.absoluteString + "/calendar/semesters"))
    }

    private static var request: BackendRequest {
        var request = BackendRequest("GET", "calendar", "semesters")
        request.authenticated = false
        return request
    }

    @Test("a request sends the stored ETag past the URL cache, and sends none without a copy")
    func requestShape() throws {
        let url = try #require(URL(string: "https://stub.invalid/feed"))
        let sent = ConditionalGet(etag: #""a""#).request(URLRequest(url: url))
        #expect(sent.value(forHTTPHeaderField: "If-None-Match") == #""a""#)
        #expect(sent.cachePolicy == .reloadIgnoringLocalCacheData)

        for etag in [nil, ""] {
            let first = ConditionalGet(etag: etag).request(URLRequest(url: url))
            #expect(first.value(forHTTPHeaderField: "If-None-Match") == nil)
            #expect(first.cachePolicy == .reloadIgnoringLocalCacheData)
        }
    }

    @Test("a 304 answers nil, and a 200 its body with the new ETag or none")
    func answers() throws {
        let url = try #require(URL(string: "https://stub.invalid/feed"))
        func response(_ status: Int, _ headers: [String: String] = [:]) throws -> HTTPURLResponse {
            try #require(HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers))
        }
        let body = Data("{}".utf8)

        #expect(ConditionalGet.answer(Data(), try response(304, ["ETag": #""a""#])) == nil)
        #expect(ConditionalGet.answer(body, try response(200, ["ETag": #""b""#])) == ETaggedBody(body: body, etag: #""b""#))
        #expect(ConditionalGet.answer(body, try response(200)) == ETaggedBody(body: body, etag: nil))
    }

    @Test("the backend's conditional GET: a 304 is nil, a 200 the copy, a returned status comes back, another throws")
    func backendRevalidate() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = try Self.feed(base)
        let body = Data(#"{"revision":1}"#.utf8)
        SettingsAPIStub.enqueue(.init(statusCode: 304, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: body, headerFields: ["ETag": #"W/"b""#]), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data(#"{"error":"gone"}"#.utf8)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: url)
        let backend = Self.backend(base)

        #expect(try await backend.revalidate(Self.request, etag: #"W/"a""#) == nil)
        let changed = try #require(try await backend.revalidate(Self.request, etag: #"W/"a""#))
        #expect(changed.copy == ETaggedBody(body: body, etag: #"W/"b""#))
        #expect(changed.status == 200)

        var returning = Self.request
        returning.returnedStatuses = [404]
        #expect(try await backend.revalidate(returning, etag: nil)?.status == 404)
        await #expect(throws: PushAPIError.self) { try await backend.revalidate(Self.request, etag: nil) }

        let sent = SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "If-None-Match") }
        #expect(sent == [#"W/"a""#, #"W/"a""#, nil, nil])
    }

    @Test("a course catalog the previous release stored reads back")
    func storedCatalogOfThePreviousRelease() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folders = CacheFolders(root: root)
        let body = Data(#"{"courses":[]}"#.utf8)
        let written = try PropertyListSerialization.data(
            fromPropertyList: ["body": body, "etag": #"W/"a""#], format: .binary, options: 0
        )
        try written.write(to: folders.cache.appendingPathComponent("course_catalog_1151_zh.plist"))

        let stored = CourseCatalogFiles(folders: folders).loadCourseCatalog(semester: "1151", language: "zh")

        #expect(stored == ETaggedBody(body: body, etag: #"W/"a""#))
    }
}
