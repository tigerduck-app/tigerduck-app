import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseCatalogClientTests {
    private static func client(_ baseURL: URL, signedIn: Bool = true) -> CourseCatalogClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return CourseCatalogClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { signedIn ? "Bearer token" : nil }
        )
    }

    private static func catalogURL(_ baseURL: URL, language: String) throws -> URL {
        try #require(URL(string: baseURL.absoluteString + "/course-catalog/1151?language=\(language)"))
    }

    @Test("a fetch sends the session and the stored ETag, and a 304 keeps the stored copy")
    func notModified() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = try Self.catalogURL(base, language: "en")
        SettingsAPIStub.enqueue(.init(statusCode: 304, body: Data()), for: url)

        let answer = try await Self.client(base).fetch(semester: "1151", language: "en", etag: #"W/"a""#)
        guard case .notModified = answer else {
            Issue.record("expected not modified, got \(answer)")
            return
        }
        let request = try #require(SettingsAPIStub.requests(for: url).first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.value(forHTTPHeaderField: "If-None-Match") == #"W/"a""#)
    }

    @Test("a new catalog comes back with its ETag, and a first fetch sends none")
    func changed() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = try Self.catalogURL(base, language: "zh")
        let body = Data(#"{"courses":[]}"#.utf8)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: body, headerFields: ["ETag": #"W/"b""#]), for: url)

        let answer = try await Self.client(base).fetch(semester: "1151", language: "zh", etag: nil)
        guard case .changed(let stored) = answer else {
            Issue.record("expected a catalog, got \(answer)")
            return
        }
        #expect(stored == StoredCourseCatalog(body: body, etag: #"W/"b""#))
        #expect(SettingsAPIStub.requests(for: url).first?.value(forHTTPHeaderField: "If-None-Match") == nil)
    }

    @Test("a term the backend has not stored is unavailable, and without a session nothing is sent")
    func unavailable() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = try Self.catalogURL(base, language: "zh")
        SettingsAPIStub.enqueue(
            .init(statusCode: 404, body: Data(#"{"detail":"course_catalog_not_found"}"#.utf8)), for: url
        )
        await #expect(throws: CourseCatalogError.unavailable) {
            try await Self.client(base).fetch(semester: "1151", language: "zh", etag: nil)
        }

        let signedOut = SettingsAPIStub.uniqueBaseURL()
        let error = await #expect(throws: PushAPIError.self) {
            try await Self.client(signedOut, signedIn: false).fetch(semester: "1151", language: "zh", etag: nil)
        }
        guard case .notSignedIn = error else {
            Issue.record("expected not signed in, got \(String(describing: error))")
            return
        }
        #expect(SettingsAPIStub.requests(under: signedOut).isEmpty)
    }
}
