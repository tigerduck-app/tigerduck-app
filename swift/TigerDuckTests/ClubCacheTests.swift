import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClubCacheTests {
    private static func client(_ base: URL) -> ClubAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return ClubAPIClient(baseURL: base, session: URLSession(configuration: config))
    }

    /// A feed with club stores of its own, so that no test reaches the app's.
    private static func feed(_ files: ClubFiles, _ base: URL) -> ClubActivities {
        ClubActivities(
            files: files, client: client(base), subscriptions: ClubSubscriptions(),
            directory: ClubDirectory(files: files, client: client(base), chinese: { true })
        )
    }

    private static func files() -> (ClubFiles, URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        return (ClubFiles(folders: CacheFolders(root: root)), root)
    }

    private static let clubs = ClubAPIModelsTests.envelope([
        ClubAPIModelsTests.club(5, "自治會", attribute: "自治性"),
        ClubAPIModelsTests.club(4, "其他社", attribute: "其他"),
        ClubAPIModelsTests.club(3, "吉他社", en: "Guitar Club", attribute: "藝術性"),
        ClubAPIModelsTests.club(2, "無性質社", attribute: nil),
        ClubAPIModelsTests.club(1, "管樂社", en: "Band", attribute: "藝術性"),
        ClubAPIModelsTests.club(6, "3D創意研究社", en: "3D Club", attribute: "學藝性"),
    ].joined(separator: ","))

    @Test("the clubs are listed by attribute, then by name, with the unclassified last")
    func listing() {
        let read = (try? ClubAPIList<ClubCard>.decode(Self.clubs)) ?? []

        #expect(ClubDirectory.listed(read, chinese: true).map(\.id) == [6, 3, 1, 5, 4, 2])
        #expect(ClubDirectory.listed(read, chinese: false).map(\.id) == [6, 1, 3, 5, 4, 2])
    }

    @Test("the directory is fetched again only after its max-age, and a failed fetch keeps it")
    func directoryFreshness() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appending(path: "clubs")
        let (files, root) = Self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let headers = ["Cache-Control": "public, max-age=300"]
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.clubs, headerFields: headers), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: url)
        let directory = ClubDirectory(files: files, client: Self.client(base), chinese: { true }, now: { clock })

        await directory.refresh()
        clock += 299
        await directory.refresh()
        #expect(SettingsAPIStub.requests(for: url).count == 1)
        #expect(directory.clubs.map(\.id) == [6, 3, 1, 5, 4, 2])

        clock += 2
        await directory.refresh()
        #expect(SettingsAPIStub.requests(for: url).count == 2)
        #expect(directory.clubs.count == 6)

        let reopened = ClubDirectory(files: files, client: Self.client(base), chinese: { true }, now: { clock - 2 })
        #expect(reopened.clubs.map(\.id) == [6, 3, 1, 5, 4, 2])
        await reopened.refresh()
        #expect(SettingsAPIStub.requests(for: url).count == 2)
    }

    @Test("the feed is asked with its ETag: a 304 keeps it, a 200 replaces it and a failure leaves it")
    func activitiesRevalidate() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appending(path: "activities")
        let (files, root) = Self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ClubAPIModelsTests.envelope(ClubAPIModelsTests.activity(1, club: 41))
        let second = ClubAPIModelsTests.envelope(ClubAPIModelsTests.activity(2, club: 41))
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: first, headerFields: ["ETag": #""a""#]), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 304, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: second, headerFields: ["ETag": #""b""#]), for: url)
        let feed = Self.feed(files, base)

        await feed.refresh()
        await feed.refresh()
        await feed.refresh()
        #expect(feed.activities.map(\.id) == [1])

        let reopened = Self.feed(files, base)
        #expect(reopened.activities.map(\.id) == [1])
        await reopened.refresh()
        #expect(reopened.activities.map(\.id) == [2])
        #expect(files.loadActivities() == ETaggedBody(body: second, etag: #""b""#))

        let sent = SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "If-None-Match") }
        #expect(sent == [nil, #""a""#, #""a""#, #""a""#])
    }

    @Test("a stored feed this build cannot read is fetched whole")
    func unreadableFeed() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appending(path: "activities")
        let (files, root) = Self.files()
        defer { try? FileManager.default.removeItem(at: root) }
        files.saveActivities(ETaggedBody(body: Data("garbage".utf8), etag: #""a""#))
        SettingsAPIStub.enqueue(.init(statusCode: 304, body: Data()), for: url)

        await Self.feed(files, base).refresh()

        #expect(SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil])
    }

    @Test("club requests go through the school's pinned session and keep no cookies, credentials or answers")
    func pinnedSession() {
        let session = ClubAPIClient.session
        #expect(session.delegate === TLSPinningDelegate.shared)
        #expect(session.configuration.httpCookieStorage == nil)
        #expect(!session.configuration.httpShouldSetCookies)
        #expect(session.configuration.urlCredentialStorage == nil)
        #expect(session.configuration.urlCache == nil)
        #expect(ClubAPIClient().session === session)
        #expect(ClubAPIClient.baseURL.host() == "clubs.ntust.edu.tw")
    }
}
