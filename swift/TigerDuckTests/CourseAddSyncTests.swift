// A course added here goes to the server through the outbox, which keeps it until it lands, and a
// full sync keeps the course here as long (https://github.com/tigerduck-app/tigerduck-app/issues/727).
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseAddSyncTests {
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        var uploadURL: URL { baseURL.appendingPathComponent("sync/courses/upload") }
        var uploads: [URLRequest] { SettingsAPIStub.requests(for: uploadURL) }

        func answer(_ status: Int, gate: SettingsAPIStub.ReplyGate? = nil) {
            SettingsAPIStub.enqueue(.init(statusCode: status, body: Data("{}".utf8), gate: gate), for: uploadURL)
        }
    }

    nonisolated private static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseAddSyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A device holding `portal` as 1151's fetched courses and `userAdded` as its hand-added ones,
    /// with `hidden` hidden.
    private static func makeCache(userAdded: [SDCourse], portal: [SDCourse] = [], hidden: [String] = []) -> DataCache {
        let root = freshDirectory()
        let cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        cache.saveCourses(portal, semester: "1151")
        cache.saveUserAddedCourses(userAdded)
        cache.saveDeletedCourseNos(hidden)
        return cache
    }

    private static func makeCoordinator(
        _ backend: Backend, cache: DataCache, outbox: SyncOutbox = SyncOutbox(directory: freshDirectory())
    ) -> CloudSyncCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { [baseURL = backend.baseURL] in baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        let push = PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
        return CloudSyncCoordinator(
            pushCoordinator: push, outbox: outbox, isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: { true },
            addedCourseUpload: { AppState.addedCourseUpload(semester: $0, courseNo: $1, cache: cache) }
        )
    }

    private static func art() -> SDCourse {
        SDCourse(courseNo: "GE1010001", courseName: "Art", semester: "1151")
    }

    @Test("A course added here whose upload fails waits in the outbox, and a full sync keeps it until it lands")
    func failedAddWaitsAndIsKept() async throws {
        let backend = Backend()
        backend.answer(503)
        backend.answer(200)
        let portal = [
            SDCourse(courseNo: "CS1001301", courseName: "Programming", moodleIdNumber: "1151CS1001301", semester: "1151"),
            SDCourse(courseNo: "EE2005301", courseName: "Circuits", moodleIdNumber: "1151EE2005301", semester: "1151"),
        ]
        let cache = Self.makeCache(userAdded: [Self.art()], portal: portal, hidden: ["1151:EE2005301"])
        let coordinator = Self.makeCoordinator(backend, cache: cache)
        let fetchedAt = Date()

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.count == 1)
        // The sign-out warning counts it, and a snapshot that lists the term without it keeps it.
        #expect(await coordinator.holdsUnsentEdits())
        let adding = await coordinator.courseAddKeys(unlandedAt: fetchedAt)
        #expect(AppState.keepsUnlistedCourse("GE1010001", semester: "1151", adding: adding))
        #expect(!AppState.keepsUnlistedCourse("GE1010001", semester: "1142", adding: adding))
        #expect(!AppState.keepsUnlistedCourse("CS1001301", semester: "1151", adding: adding))

        await coordinator.syncTick()

        #expect(backend.uploads.count == 2)
        #expect(!(await coordinator.holdsUnsentEdits()))
        let upload = try #require(backend.uploads.last)
        let body = try #require(SettingsAPIStub.bodyData(from: upload))
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["force_keys"] as? [String] == ["client:1151:GE1010001"])
        // The term as shown here: a term whose roster had not reached the server gets all of it.
        let sent = (json["courses"] as? [[String: Any]])?.compactMap { $0["course_no"] as? String }
        #expect(sent?.sorted() == ["CS1001301", "GE1010001"])
        // A snapshot fetched before the upload landed may still lack the course; a later one has it.
        #expect(await coordinator.courseAddKeys(unlandedAt: fetchedAt) == ["1151:GE1010001"])
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()).isEmpty)
    }

    /// The course is saved here before its add reaches the outbox, which a full sync can read meanwhile.
    @Test("An add on its way into the outbox already counts for a full sync and for the sign-out warning")
    func addOnItsWayInCounts() async {
        let backend = Backend()
        backend.answer(503)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))

        let add = coordinator.addCourse(semester: "1151", courseNo: "GE1010001")

        #expect(await coordinator.holdsUnsentEdits())
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()) == ["1151:GE1010001"])
        await add.value
    }

    /// Taken back in Add Course, or deleted or hidden here, before its upload went.
    @Test("An add whose course is gone or hidden here when it goes is dropped unsent", arguments: [false, true])
    func addOfAGoneCourseIsDropped(hidden: Bool) async {
        let backend = Backend()
        let cache = Self.makeCache(userAdded: hidden ? [Self.art()] : [], hidden: hidden ? ["1151:GE1010001"] : [])
        let coordinator = Self.makeCoordinator(backend, cache: cache)

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.isEmpty)
        #expect(!(await coordinator.holdsUnsentEdits()))
        #expect(await coordinator.courseAddKeys(unlandedAt: .distantPast).isEmpty)
    }

    @Test("An add the server keeps refusing is parked, so a full sync still keeps its course and tries it again")
    func refusedAddIsParked() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE1010001", stamp: Date()))

        for _ in 0..<SyncOutbox.maxAttempts {
            await outbox.drain { _ in throw PushAPIError.httpStatus(422, body: "") }
        }

        #expect(await outbox.pendingCount() == 0)
        let coordinator = Self.makeCoordinator(Backend(), cache: Self.makeCache(userAdded: []), outbox: outbox)
        #expect(await coordinator.holdsUnsentEdits())
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()) == ["1151:GE1010001"])
        await coordinator.requeueParkedMarks()
        #expect(await outbox.pendingCount() == 1)
    }

    @Test("A queued add survives a relaunch")
    func queuedAddSurvivesARelaunch() async throws {
        let directory = Self.freshDirectory()
        await SyncOutbox(directory: directory).enqueue(.courseAdd(semester: "1151", courseNo: "GE1010001", stamp: Date()))

        let op = try #require(await SyncOutbox(directory: directory).snapshot().first?.op)

        guard case let .courseAdd(semester, courseNo, _) = op else {
            Issue.record("decoded as \(op)")
            return
        }
        #expect(semester == "1151")
        #expect(courseNo == "GE1010001")
    }

    /// A 5xx says nothing about most edits, but a whole-term upload can fail on its payload alone.
    @Test("An add the server keeps failing with 5xx spends its attempts and parks, so the ops behind it still go")
    func failingAddDoesNotHoldTheQueue() async {
        let backend = Backend()
        for _ in 0..<SyncOutbox.maxAttempts { backend.answer(503) }
        let deleteURL = backend.baseURL.appendingPathComponent("sync/courses/client:1151:CS1001301")
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"deleted": 1}"#.utf8)), for: deleteURL)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value
        await coordinator.deleteCourse(semester: "1151", courseNo: "CS1001301")

        #expect(SettingsAPIStub.requests(for: deleteURL).count == 1)
        for _ in 2..<SyncOutbox.maxAttempts { await coordinator.syncTick() }
        #expect(backend.uploads.count == SyncOutbox.maxAttempts)
        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()) == ["1151:GE1010001"])
    }

    /// Sent beside the delete, the upload could land first and the delete remove the course again.
    @Test("A course added back while its delete is being sent goes up once that delete has landed")
    func addGoesAfterAnInFlightDelete() async throws {
        let backend = Backend()
        let deleteURL = backend.baseURL.appendingPathComponent("sync/courses/client:1151:GE1010001")
        let gate = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"deleted": 1}"#.utf8), gate: gate), for: deleteURL)
        backend.answer(200)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))
        let delete = Task { await coordinator.deleteCourse(semester: "1151", courseNo: "GE1010001") }
        try await waitUntil { !SettingsAPIStub.requests(for: deleteURL).isEmpty }

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value
        #expect(backend.uploads.isEmpty)
        gate.open()
        await delete.value

        try await waitUntil(timeout: .seconds(10)) { backend.uploads.count == 1 }
        let order = SettingsAPIStub.requests(under: backend.baseURL).map(\.httpMethod)
        #expect(order == ["DELETE", "POST"])
    }
}
