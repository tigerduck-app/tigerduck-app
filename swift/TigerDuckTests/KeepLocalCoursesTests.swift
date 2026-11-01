import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct KeepLocalCoursesTests {
    private static func roster(_ courseNos: String...) -> [SDCourse] {
        courseNos.map { SDCourse(courseNo: $0, courseName: $0) }
    }

    @Test("a course deleted here stays deleted after Use Local and the next roster upload",
          arguments: [false, true])
    func deletedCourseStaysDeleted(deletedOnServer: Bool) async throws {
        let server = FakeCourseServer(
            rows: deletedOnServer ? ["client:1151:CS1"] : ["client:1151:CS1", "client:1151:CS2"],
            tombstones: deletedOnServer ? ["client:1151:CS2": false] : [:]
        )
        let roster = Self.roster("CS1", "CS2")

        try await SyncConflicts.keepLocalCourses([("1151", roster)], hiding: ["1151:CS2"], on: server, for: testSignIn)
        #expect(server.rows == ["client:1151:CS1"])

        try await server.uploadCourses(SchoolDataUploader.courseUploadRequest(roster, semester: "1151"), addedAt: nil, for: testSignIn)
        #expect(server.rows == ["client:1151:CS1"])
    }

    @Test("a course hidden here but missing from the cache stays deleted",
          arguments: [false, true], [false, true])
    func uncachedHiddenCourseStaysDeleted(deletedOnServer: Bool, termCached: Bool) async throws {
        let cached = termCached ? Self.roster("CS1") : []
        let cachedKeys = Set(cached.map { "client:1151:\($0.courseNo)" })
        let server = FakeCourseServer(
            rows: deletedOnServer ? cachedKeys : cachedKeys.union(["client:1151:CS2"]),
            tombstones: deletedOnServer ? ["client:1151:CS2": false] : [:]
        )

        try await SyncConflicts.keepLocalCourses([("1151", cached)], hiding: ["1151:CS2"], on: server, for: testSignIn)

        try await server.uploadCourses(SchoolDataUploader.courseUploadRequest(
            cached + Self.roster("CS2"), semester: "1151"
        ), addedAt: nil, for: testSignIn)
        #expect(server.rows == cachedKeys)
    }

    @Test("a legacy entry, which hides its course in every term, keeps it deleted when the cache lacks it")
    func uncachedLegacyHiddenCourseStaysDeleted() async throws {
        let server = FakeCourseServer(rows: ["client:1151:CS1"], tombstones: ["client:1151:CS2": false])

        try await SyncConflicts.keepLocalCourses([("1151", Self.roster("CS1"))], hiding: ["CS2"], on: server, for: testSignIn)

        try await server.uploadCourses(SchoolDataUploader.courseUploadRequest(
            Self.roster("CS1", "CS2"), semester: "1151"
        ), addedAt: nil, for: testSignIn)
        #expect(server.rows == ["client:1151:CS1"])
    }

    @Test("a retry after a failed delete finishes it")
    func retryAfterFailedDelete() async throws {
        let server = FakeCourseServer(rows: ["client:1151:CS1", "client:1151:CS2"])
        let roster = Self.roster("CS1", "CS2")
        server.failingDeletes = 1

        await #expect(throws: URLError.self) {
            try await SyncConflicts.keepLocalCourses([("1151", roster)], hiding: ["1151:CS2"], on: server, for: testSignIn)
        }
        try await SyncConflicts.keepLocalCourses([("1151", roster)], hiding: ["1151:CS2"], on: server, for: testSignIn)

        try await server.uploadCourses(SchoolDataUploader.courseUploadRequest(roster, semester: "1151"), addedAt: nil, for: testSignIn)
        #expect(server.rows == ["client:1151:CS1"])
    }

    @Test("Use Local resets only the terms it re-uploads, never every term at once")
    func resetsTermByTerm() async throws {
        let server = FakeCourseServer(rows: ["client:1151:CS1", "client:1142:CS9"])

        try await SyncConflicts.keepLocalCourses(
            [("1151", Self.roster("CS1")), ("1142", [])], hiding: [], on: server, for: testSignIn
        )

        #expect(server.fullResets == 0)
        #expect(server.rows == ["client:1151:CS1", "client:1142:CS9"])
    }

    @Test("Use Local sends nothing more once the sign-in it was answered under is gone")
    func stopsAfterASignOut() async {
        let server = FakeCourseServer(rows: ["client:1151:CS1", "client:1142:CS9"])
        let signedIn = TestSignIn()
        server.afterSend = { signedIn.signOut() }

        await #expect(throws: PushAPIError.self) {
            try await SyncConflicts.keepLocalCourses(
                [("1151", Self.roster("CS1")), ("1142", Self.roster("CS9"))], hiding: [], on: server, for: signedIn.signIn
            )
        }

        #expect(server.rows == ["client:1142:CS9"])
    }

    @Test("Use Local holds a reset refused as ahead once cloud sync turns off during its first send")
    func aheadResetWaitsOnceSyncTurnsOff() async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.cloudSyncEnabled]
            defer { Defaults[.cloudSyncEnabled, for: testSignIn] = saved }
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            let server = StampedCourseServer()
            let reset = server.baseURL.appendingPathComponent("sync/courses").appending(queryItems: [
                URLQueryItem(name: "semester", value: "1151"),
                URLQueryItem(name: "hlc", value: String(PushAPI.clock(of: StampedCourseServer.madeAt))),
            ])
            let gate = SettingsAPIStub.ReplyGate()
            SettingsAPIStub.enqueue(.init(
                statusCode: 409, body: Data(#"{"error":"clock_ahead","message":"ahead"}"#.utf8),
                headerFields: ["X-TigerSync-Clock": "1789999000000000"], gate: gate
            ), for: reset)

            let answer = Task {
                try await SyncConflicts.keepLocalCourses([("1151", Self.roster("CS1"))], hiding: [], on: server, for: testSignIn)
            }
            try await waitUntil { !SettingsAPIStub.requests(for: reset).isEmpty }
            Defaults[.cloudSyncEnabled, for: testSignIn] = false
            gate.open()

            await #expect(throws: ResendHeldError.self) { try await answer.value }
            #expect(SettingsAPIStub.requests(under: server.baseURL).count == 1)
        }
    }
}

/// Sends through the real client, every edit stamped with `madeAt`, so a test can stub its URL.
@MainActor
private final class StampedCourseServer: CourseSyncBackend {
    static let madeAt = Date(timeIntervalSince1970: 1_790_000_000)
    let baseURL: URL
    private let client: PushAPIClient

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        self.baseURL = baseURL
        client = PushAPIClient(
            baseURLProvider: { baseURL }, session: URLSession(configuration: config), authHeaderProvider: { "Bearer test" }
        )
    }

    func deleteAllCourses(semester: String?, madeAt: Date, for signIn: SignIn) async throws {
        try await client.deleteAllCourses(semester: semester, madeAt: Self.madeAt, for: signIn)
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt: Date?, for signIn: SignIn) async throws {
        try await client.uploadCourses(request, addedAt: addedAt, for: signIn)
    }

    func deleteCourse(courseKey: String, madeAt: Date, for signIn: SignIn) async throws {
        try await client.deleteCourse(courseKey: courseKey, madeAt: Self.madeAt, for: signIn)
    }
}

@MainActor
private final class FakeCourseServer: CourseSyncBackend {
    private(set) var rows: Set<String>
    private(set) var tombstones: [String: Bool]
    private(set) var fullResets = 0
    var failingDeletes = 0
    var afterSend: () -> Void = {}

    init(rows: Set<String>, tombstones: [String: Bool] = [:]) {
        self.rows = rows
        self.tombstones = tombstones
    }

    func deleteAllCourses(semester: String?, madeAt: Date, for signIn: SignIn) async throws {
        guard signIn.isCurrent else { throw PushAPIError.notSignedIn }
        defer { afterSend() }
        guard let semester else {
            fullResets += 1
            rows = []
            tombstones = [:]
            return
        }
        let prefix = "client:\(semester):"
        let removed = rows.filter { $0.hasPrefix(prefix) }
        rows.subtract(removed)
        for key in tombstones.keys where key.hasPrefix(prefix) { tombstones[key] = true }
        for key in removed { tombstones[key] = true }
    }

    func uploadCourses(_ request: PushAPI.CourseUploadRequest, addedAt: Date?, for signIn: SignIn) async throws {
        guard signIn.isCurrent else { throw PushAPIError.notSignedIn }
        defer { afterSend() }
        for add in request.handAddedCourses ?? [] { tombstones[add.courseKey] = nil }
        let keys = request.courses.map { "client:\($0.semester):\($0.courseNo)" }
        for key in keys where tombstones[key] == true { tombstones[key] = nil }
        rows.formUnion(keys.filter { tombstones[$0] == nil })
    }

    func deleteCourse(courseKey: String, madeAt: Date, for signIn: SignIn) async throws {
        guard signIn.isCurrent else { throw PushAPIError.notSignedIn }
        defer { afterSend() }
        if failingDeletes > 0 {
            failingDeletes -= 1
            throw URLError(.networkConnectionLost)
        }
        guard rows.remove(courseKey) != nil else { return }
        tombstones[courseKey] = tombstones[courseKey] ?? false
    }
}
