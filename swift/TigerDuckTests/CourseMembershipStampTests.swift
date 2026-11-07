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
        var landed: Bool { reply.statusCode == 200 }

        static let lands = Attempt(reply: .init(statusCode: 200, body: Data("{}".utf8)))
        static let loses = Attempt(reply: .noReply)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        let edit: Edit
        let attempts: [Attempt]

        static let all = [
            Case(testDescription: "A hide queued before a re-add elsewhere goes with its age",
                 edit: .hide, attempts: [.lands]),
            Case(testDescription: "A hide whose reply was lost goes again with its age",
                 edit: .hide, attempts: [.loses, .lands]),
            Case(testDescription: "An add queued before a hide or reset elsewhere goes with its age",
                 edit: .add, attempts: [.lands]),
            Case(testDescription: "An add whose reply was lost goes again with its age",
                 edit: .add, attempts: [.loses, .lands]),
        ]
    }

    private static let madeAt = Date(timeIntervalSince1970: 1_790_000_000.5)
    private static let age = "1500"
    private static let key = "client:1151:GE1010001"

    @Test(arguments: Case.all)
    func eachAttemptCarriesTheTimeTheEditWasMade(_ example: Case) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let path = baseURL.appendingPathComponent(
            example.edit == .hide ? "sync/courses/\(Self.key)" : "sync/courses/upload"
        )
        let stamped = example.edit == .hide ? path.appending(queryItems: [URLQueryItem(name: "age_ms", value: Self.age)]) : path
        for attempt in example.attempts {
            SettingsAPIStub.enqueue(attempt.reply, for: stamped)
        }
        let coordinator = Self.makeCoordinator(baseURL, hidingTheCourse: example.edit == .hide)

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
        for request in sent {
            switch example.edit {
            case .hide:
                #expect(request.url == stamped)
            case .add:
                try Self.expectAdd(request)
            }
        }
        #expect(await coordinator.outbox.pendingCount() == (example.attempts.last?.landed == true ? 0 : 1))
    }

    private static func expectAdd(_ request: URLRequest) throws {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["force_keys"] == nil)
        #expect((json["courses"] as? [[String: Any]])?.compactMap { $0["course_no"] as? String } == ["GE1010001"])
        let adds = json["adds"] as? [[String: Any]]
        #expect(adds?.count == 1)
        #expect(adds?.first?["course_key"] as? String == key)
        #expect((adds?.first?["age_ms"] as? NSNumber)?.int64Value == Int64(age))
        #expect(adds?.first?["hlc"] == nil)
    }

    private static func makeCoordinator(
        _ baseURL: URL,
        hidingTheCourse: Bool = false,
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
        if hidingTheCourse { cache.courses.saveDeletedCourseNos(["1151:GE1010001"], for: testSignIn) }
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
            account: AccountSession(signIns: testSignIns), courses: cache.courses
        )
    }
}
