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

    private static func makePush(_ backend: Backend) -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { [baseURL = backend.baseURL] in baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
    }

    /// No colours go up, so a list's fingerprint does not follow the real Defaults.
    private static func makeCoordinator(
        _ backend: Backend, cache: DataCache, outbox: SyncOutbox = SyncOutbox(directory: freshDirectory()),
        push: PushCoordinator? = nil, uploadsCourses: @escaping @MainActor () -> Bool = { true },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true },
        loginGeneration: @escaping @MainActor () -> Int = { 0 }
    ) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            pushCoordinator: push ?? makePush(backend), outbox: outbox, isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: { true },
            addedCourseUpload: { AppState.addedCourseUpload(semester: $0, courseNo: $1, cache: cache, colors: [:]) },
            uploadsCourses: uploadsCourses, isProtectedDataAvailable: isProtectedDataAvailable,
            loginGeneration: loginGeneration
        )
    }

    @MainActor
    private final class Switch {
        var isOn = true
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
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: ["CS1001301"], tombstoned: ["GE1010001"], fetched: ["CS1001301"],
            handAdded: ["GE1010001"], hidden: [], adding: adding
        )
        #expect(unlisted.hide.isEmpty)
        #expect(unlisted.drop.isEmpty)

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

    /// Use Server takes the server's courses over the adds still on their way up.
    @Test("Use Server for courses drops a course add still queued, and other categories keep it")
    func useServerDropsAQueuedAdd() async {
        let backend = Backend()
        backend.answer(503)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))
        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        await coordinator.discardEdits(of: ["course_colors", "course_names", "assignments"], courseIgnores: true)
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()) == ["1151:GE1010001"])

        await coordinator.discardEdits(of: ["courses"], courseIgnores: false)
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()).isEmpty)
    }

    /// Behind the lock screen the course list reads as empty, and the add would be dropped as gone.
    @Test("A course add waits in the outbox while protected data is locked, and goes after unlock")
    func addWaitsBehindTheLock() async {
        let backend = Backend()
        let unlocked = Switch()
        unlocked.isOn = false
        let coordinator = Self.makeCoordinator(
            backend, cache: Self.makeCache(userAdded: [Self.art()]), isProtectedDataAvailable: { unlocked.isOn }
        )

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.isEmpty)
        #expect(await coordinator.courseAddKeys(unlandedAt: .distantPast) == ["1151:GE1010001"])

        unlocked.isOn = true
        await coordinator.syncTick()
        #expect(backend.uploads.count == 1)
    }

    /// The drain samples the lock once per pass, and the lock can land before the add's turn comes.
    @Test("A course add waits when the lock lands during the drain's pass")
    func addWaitsWhenTheLockLandsMidPass() async {
        let backend = Backend()
        let unlocked = Switch()
        let coordinator = Self.makeCoordinator(
            backend, cache: Self.makeCache(userAdded: [Self.art()]),
            isProtectedDataAvailable: { defer { unlocked.isOn = false }; return unlocked.isOn }
        )

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.isEmpty)
        #expect(await coordinator.courseAddKeys(unlandedAt: .distantPast) == ["1151:GE1010001"])
    }

    /// A sign-out while the add waits in the term's upload chain leaves its list with the departing account.
    @Test("A course add is not sent once the login has changed since its list was read")
    func addOfAnEarlierLoginIsNotSent() async {
        let backend = Backend()
        let signedOut = Switch()
        signedOut.isOn = false
        let coordinator = Self.makeCoordinator(
            backend, cache: Self.makeCache(userAdded: [Self.art()]),
            loginGeneration: { defer { signedOut.isOn = true }; return signedOut.isOn ? 1 : 0 }
        )

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.isEmpty)
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

    /// The other course keys name the same courses in another term, which an add here does not cover.
    @Test("A course a filled term's snapshot does not list goes, by tombstone, by absence or as hand-added, unless its add from here had not landed",
          arguments: [false, true])
    func unlistedCourseStaysWhileItsAddIsOut(adding: Bool) {
        let keys = adding
            ? ["1151:GE1010001", "1151:EE2005301", "1151:MA1010003"]
            : ["1142:GE1010001", "1142:EE2005301", "1142:MA1010003"]

        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: ["CS1001301"], tombstoned: ["GE1010001"], fetched: ["CS1001301", "EE2005301"],
            handAdded: ["MA1010003"], hidden: [], adding: Set(keys)
        )

        #expect(unlisted.hide == (adding ? [] : ["GE1010001", "EE2005301"]))
        #expect(unlisted.drop == (adding ? [] : ["MA1010003"]))
    }

    @Test("An empty term's snapshot hides only by tombstone, and a course hidden already is not hidden again")
    func emptyTermHidesOnlyByTombstone() {
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: [], tombstoned: ["GE1010001", "PE1010002"], fetched: ["CS1001301"],
            handAdded: ["MA1010003"], hidden: ["1151:PE1010002"], adding: []
        )

        #expect(unlisted.hide == ["GE1010001"])
        #expect(unlisted.drop.isEmpty)
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

    /// As when the Mac's "All courses" switch goes off while an add waits offline.
    @Test("An add that comes due once course uploads are off is dropped unsent")
    func addAfterAnOptOutIsDropped() async {
        let backend = Backend()
        backend.answer(503)
        let uploads = Switch()
        let coordinator = Self.makeCoordinator(
            backend, cache: Self.makeCache(userAdded: [Self.art()]), uploadsCourses: { uploads.isOn }
        )
        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        uploads.isOn = false
        await coordinator.syncTick()

        #expect(backend.uploads.count == 1)
        #expect(!(await coordinator.holdsUnsentEdits()))
    }

    /// The chain every upload of the term takes, so the one queued last lands last. It notes the list
    /// as taken, which lets an edit that sends the same list after it skip it.
    @Test("An add goes up through its term's upload chain")
    func addGoesThroughItsTermsUploadChain() async throws {
        let backend = Backend()
        backend.answer(200)
        backend.answer(200)
        let push = Self.makePush(backend)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]), push: push)

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        let sameList = AppState.courseUploadRequest([Self.art()], semester: "1151", forceKeys: [], colors: [:])
        #expect(try await !push.uploadCoursesIfChanged(sameList, semester: "1151", isCurrent: { true }))
        #expect(backend.uploads.count == 1)
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
