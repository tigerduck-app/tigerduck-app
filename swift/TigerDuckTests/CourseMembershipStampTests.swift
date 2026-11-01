import Foundation
import Testing
@testable import TigerDuck

/// The backend settles a queued course add or hide against another device's re-add, hide or
/// reset, and against its own retry, by the time each was made (tigerduck-app/tigerduck-app#689).
@MainActor
struct CourseMembershipStampTests {
    enum Edit: Sendable { case hide, add }

    struct Attempt: Sendable {
        let reply: SettingsAPIStub.StubResponse
        let sentStamp: String
        var landed: Bool { reply.statusCode == 200 }

        static let serverClock = "1789999000000000"
        static let lands = Attempt(reply: .init(statusCode: 200, body: Data("{}".utf8)), sentStamp: CourseMembershipStampTests.hlc)
        static let loses = Attempt(reply: .noReply, sentStamp: CourseMembershipStampTests.hlc)
        static let refusedAsAhead = Attempt(
            reply: .init(
                statusCode: 409, body: Data(#"{"error":"clock_ahead","message":"ahead"}"#.utf8),
                headerFields: ["X-TigerSync-Clock": serverClock]
            ),
            sentStamp: CourseMembershipStampTests.hlc
        )
        static let otherConflict = Attempt(
            reply: .init(statusCode: 409, body: Data(#"{"error":"something_else","message":"other"}"#.utf8)),
            sentStamp: CourseMembershipStampTests.hlc
        )
        static let landsRestamped = Attempt(reply: .init(statusCode: 200, body: Data("{}".utf8)), sentStamp: serverClock)
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
            Case(testDescription: "A hide stamped ahead of the server's clock goes again stamped from that clock",
                 edit: .hide, attempts: [.refusedAsAhead, .landsRestamped]),
            Case(testDescription: "A hide answered with another conflict stays queued with its time",
                 edit: .hide, attempts: [.otherConflict, .otherConflict]),
            Case(testDescription: "An add queued before a hide or reset elsewhere goes with the time it was made",
                 edit: .add, attempts: [.lands]),
            Case(testDescription: "An add whose reply was lost goes again with the same time",
                 edit: .add, attempts: [.loses, .lands]),
            Case(testDescription: "An add stamped ahead of the server's clock goes again stamped from that clock",
                 edit: .add, attempts: [.refusedAsAhead, .landsRestamped]),
            Case(testDescription: "An add answered with another conflict stays queued with its time",
                 edit: .add, attempts: [.otherConflict, .otherConflict]),
        ]
    }

    private static let madeAt = Date(timeIntervalSince1970: 1_790_000_000.5)
    fileprivate static let hlc = "1790000000500000"
    private static let key = "client:1151:GE1010001"

    @Test(arguments: Case.all)
    func eachAttemptCarriesTheTimeTheEditWasMade(_ example: Case) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let path = baseURL.appendingPathComponent(
            example.edit == .hide ? "sync/courses/\(Self.key)" : "sync/courses/upload"
        )
        let stamped = { (hlc: String) in
            example.edit == .hide ? path.appending(queryItems: [URLQueryItem(name: "hlc", value: hlc)]) : path
        }
        for attempt in example.attempts {
            SettingsAPIStub.enqueue(attempt.reply, for: stamped(attempt.sentStamp))
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
                #expect(request.url == stamped(attempt.sentStamp))
            case .add:
                try Self.expectAdd(request, hlc: attempt.sentStamp)
            }
        }
        #expect(await coordinator.outbox.pendingCount() == (example.attempts.last?.landed == true ? 0 : 1))
    }

    enum Hold: Sendable, CaseIterable { case courseSyncOff, dataLocked }

    @MainActor
    private final class Switch {
        var on = false
    }

    @Test("An add refused as ahead waits when course sync turns off or data locks during its first send",
          arguments: Hold.allCases)
    func aheadAddWaitsForAHoldStartedDuringTheSend(_ hold: Hold) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("sync/courses/upload")
        var refused = Attempt.refusedAsAhead.reply
        let gate = SettingsAPIStub.ReplyGate()
        refused.gate = gate
        SettingsAPIStub.enqueue(refused, for: url)
        let held = Switch()
        let coordinator = Self.makeCoordinator(
            baseURL,
            uploadsCourses: { !(hold == .courseSyncOff && held.on) },
            isProtectedDataAvailable: { !(hold == .dataLocked && held.on) }
        )
        await coordinator.outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE1010001", stamp: Self.madeAt))

        let tick = Task { await coordinator.syncTick() }
        try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
        held.on = true
        gate.open()
        await tick.value

        #expect(SettingsAPIStub.requests(for: url).count == 1)
        #expect(await coordinator.outbox.snapshot().map(\.attempts) == [0])
    }

    private static func expectAdd(_ request: URLRequest, hlc: String) throws {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["force_keys"] == nil)
        #expect((json["courses"] as? [[String: Any]])?.compactMap { $0["course_no"] as? String } == ["GE1010001"])
        let adds = json["adds"] as? [[String: Any]]
        #expect(adds?.count == 1)
        #expect(adds?.first?["course_key"] as? String == key)
        #expect((adds?.first?["hlc"] as? NSNumber)?.int64Value == Int64(hlc))
    }

    private static func makeCoordinator(
        _ baseURL: URL,
        uploadsCourses: @escaping @MainActor () -> Bool = { true },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true }
    ) -> CloudSyncCoordinator {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseMembershipStampTests-\(UUID().uuidString)", isDirectory: true)
        let cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        cache.courses.saveCourses([SDCourse(courseNo: "CS1001301", courseName: "Programming", semester: "1151")], semester: "1151", for: testSignIn)
        cache.courses.saveUserAddedCourses([SDCourse(courseNo: "GE1010001", courseName: "Art", semester: "1151")], for: testSignIn)
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
            addedCourseUpload: { SchoolDataUploader.addedCourseUpload(semester: $0, courseNo: $1, courses: cache.courses) },
            uploadsCourses: uploadsCourses, isProtectedDataAvailable: isProtectedDataAvailable,
            account: AccountSession(signIns: testSignIns)
        )
    }
}
