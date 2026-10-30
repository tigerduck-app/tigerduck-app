import Foundation
import Testing
@testable import TigerDuck

/// The backend settles a queued course add or hide against another device's re-add, hide or
/// reset, and against its own retry, by the time each was made (tigerduck-app/tigerduck-app#689).
/// These check that every attempt of a queued edit carries the time it was made.
@MainActor
struct CourseMembershipStampTests {
    enum Edit: Sendable { case hide, add }

    struct Attempt: Sendable {
        let reply: SettingsAPIStub.StubResponse
        let stamped: Bool

        static let lands = Attempt(reply: .init(statusCode: 200, body: Data("{}".utf8)), stamped: true)
        static let loses = Attempt(reply: .noReply, stamped: true)
        static let refusedAsAhead = Attempt(
            reply: .init(statusCode: 409, body: Data(#"{"detail":"clock_ahead"}"#.utf8)), stamped: true
        )
        static let landsUnstamped = Attempt(reply: .init(statusCode: 200, body: Data("{}".utf8)), stamped: false)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let edit: Edit
        let attempts: [Attempt]

        static let all = [
            Case(testDescription: "A hide queued before a re-add elsewhere goes with the time it was made",
                 edit: .hide, attempts: [.lands]),
            Case(testDescription: "A hide whose reply was lost goes again with the same time",
                 edit: .hide, attempts: [.loses, .lands]),
            Case(testDescription: "A hide stamped ahead of the server's clock goes again without its time",
                 edit: .hide, attempts: [.refusedAsAhead, .landsUnstamped]),
            Case(testDescription: "An add queued before a hide or reset elsewhere goes with the time it was made",
                 edit: .add, attempts: [.lands]),
            Case(testDescription: "An add whose reply was lost goes again with the same time",
                 edit: .add, attempts: [.loses, .lands]),
            Case(testDescription: "An add stamped ahead of the server's clock goes again with its key forced",
                 edit: .add, attempts: [.refusedAsAhead, .landsUnstamped]),
        ]
    }

    private static let madeAt = Date(timeIntervalSince1970: 1_790_000_000.5)
    private static let hlc = "1790000000500000"
    private static let key = "client:1151:GE1010001"

    @Test(arguments: Case.all)
    func eachAttemptCarriesTheTimeTheEditWasMade(_ example: Case) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let path = baseURL.appendingPathComponent(
            example.edit == .hide ? "sync/courses/\(Self.key)" : "sync/courses/upload"
        )
        let stampedPath = example.edit == .hide
            ? path.appending(queryItems: [URLQueryItem(name: "hlc", value: Self.hlc)])
            : path
        for attempt in example.attempts {
            SettingsAPIStub.enqueue(attempt.reply, for: attempt.stamped ? stampedPath : path)
        }
        let coordinator = Self.makeCoordinator(baseURL)

        switch example.edit {
        case .hide:
            await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "GE1010001", at: Self.madeAt)
        case .add:
            await coordinator.outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE1010001", stamp: Self.madeAt))
        }
        await coordinator.syncTick()
        await coordinator.syncTick()

        let sent = SettingsAPIStub.requests(under: baseURL)
        #expect(sent.count == example.attempts.count)
        for (request, attempt) in zip(sent, example.attempts) {
            switch example.edit {
            case .hide:
                #expect(request.url == (attempt.stamped ? stampedPath : path))
            case .add:
                try Self.expectAdd(request, stamped: attempt.stamped)
            }
        }
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    private static func expectAdd(_ request: URLRequest, stamped: Bool) throws {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(request.value(forHTTPHeaderField: "X-TigerSync-Protocol") == (stamped ? "2" : nil))
        #expect(json["force_keys"] as? [String] == [key])
        #expect((json["courses"] as? [[String: Any]])?.compactMap { $0["course_no"] as? String } == ["GE1010001"])
        let adds = json["adds"] as? [[String: Any]]
        if stamped {
            #expect(adds?.count == 1)
            #expect(adds?.first?["course_key"] as? String == key)
            #expect((adds?.first?["hlc"] as? NSNumber)?.int64Value == Int64(hlc))
        } else {
            #expect(adds == nil)
        }
    }

    private static func makeCoordinator(_ baseURL: URL) -> CloudSyncCoordinator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseMembershipStampTests-\(UUID().uuidString)", isDirectory: true)
        let cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        cache.saveCourses([SDCourse(courseNo: "CS1001301", courseName: "Programming", semester: "1151")], semester: "1151")
        cache.saveUserAddedCourses([SDCourse(courseNo: "GE1010001", courseName: "Art", semester: "1151")])
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        return CloudSyncCoordinator(
            pushCoordinator: PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client),
            outbox: SyncOutbox(directory: root.appendingPathComponent("outbox", isDirectory: true)), isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: { true }, syncsCourseOverrides: { _ in true },
            addedCourseUpload: { AppState.addedCourseUpload(semester: $0, courseNo: $1, cache: cache, colors: [:]) },
            uploadsCourses: { true }, isProtectedDataAvailable: { true }
        )
    }
}
