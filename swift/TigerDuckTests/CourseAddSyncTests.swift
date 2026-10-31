import Foundation
import os
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

    private static func makeCoordinator(
        _ backend: Backend, cache: DataCache, outbox: SyncOutbox = SyncOutbox(directory: freshDirectory()),
        push: PushCoordinator? = nil, uploadsCourses: @escaping @MainActor () -> Bool = { true },
        isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true },
        account: AccountSession = AccountSession(),
        whileReading: @escaping @MainActor () -> Void = {}
    ) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            pushCoordinator: push ?? makePush(backend), outbox: outbox, isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: { true }, syncsCourseOverrides: { _ in true },
            addedCourseUpload: {
                whileReading()
                return AppState.addedCourseUpload(semester: $0, courseNo: $1, cache: cache, colors: [:])
            },
            uploadsCourses: uploadsCourses, isProtectedDataAvailable: isProtectedDataAvailable,
            account: account
        )
    }

    @MainActor
    private final class Switch {
        var isOn = true
    }

    private static let hiddenAt = Date(timeIntervalSince1970: 1_790_000_000)

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
        #expect(await coordinator.holdsUnsentEdits())
        let adding = await coordinator.courseAddKeys(unlandedAt: fetchedAt)
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: ["CS1001301"], tombstoned: ["GE1010001"], fetched: ["CS1001301"],
            handAdded: ["GE1010001"], droppedMerges: [], hidden: [], adding: adding
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
        let sent = (json["courses"] as? [[String: Any]])?.compactMap { $0["course_no"] as? String }
        #expect(sent == ["GE1010001"])
        #expect(await coordinator.courseAddKeys(unlandedAt: fetchedAt) == ["1151:GE1010001"])
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()).isEmpty)
    }

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

    @Test("A course add is not sent once the login has changed since its list was read")
    func addOfAnEarlierLoginIsNotSent() async {
        let backend = Backend()
        let account = AccountSession()
        let coordinator = Self.makeCoordinator(
            backend, cache: Self.makeCache(userAdded: [Self.art()]),
            account: account, whileReading: { account.moveOn() }
        )

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.isEmpty)
    }

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

    @Test("An add whose course is gone or hidden here when it goes is dropped unsent", arguments: [false, true])
    func addOfAGoneCourseIsDropped(hidden: Bool) async {
        let backend = Backend()
        let cache = Self.makeCache(userAdded: hidden ? [Self.art()] : [], hidden: hidden ? ["1151:GE1010001"] : [])
        let coordinator = Self.makeCoordinator(backend, cache: cache)

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(backend.uploads.isEmpty)
        #expect(!(await coordinator.holdsUnsentEdits()))
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()).isEmpty)
    }

    @Test("A sign-out forgets when the adds landed, so none counts for the next account's full sync")
    func signOutForgetsTheAddTimes() async {
        let coordinator = Self.makeCoordinator(Backend(), cache: Self.makeCache(userAdded: [Self.art()]))
        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value
        #expect(await coordinator.courseAddKeys(unlandedAt: .distantPast) == ["1151:GE1010001"])

        await coordinator.settleForSignOut()

        #expect(await coordinator.courseAddKeys(unlandedAt: .distantPast).isEmpty)
    }

    @Test("An add counts for a full sync whose fetch began before it, though it left the outbox unsent")
    func addCountsForASyncThatBeganBeforeIt() async {
        let cache = Self.makeCache(userAdded: [Self.art()], hidden: ["1151:GE1010001"])
        let coordinator = Self.makeCoordinator(Backend(), cache: cache)
        let fetchedAt = Date()

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value

        #expect(!(await coordinator.holdsUnsentEdits()))
        #expect(await coordinator.courseAddKeys(unlandedAt: fetchedAt) == ["1151:GE1010001"])
    }

    /// The outbox can take an add's enqueue after a full sync read it, so the add is in neither read.
    /// The read is held on a queue file the outbox has not loaded yet, as behind the lock screen.
    @Test("An add that starts while a full sync reads the outbox still counts")
    func addDuringTheReadCounts() async throws {
        let backend = Backend()
        backend.answer(503)
        let directory = Self.freshDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for name in ["outbox.json", "outbox-parked.json"] {
            try Data("[]".utf8).write(to: directory.appendingPathComponent(name))
        }
        let locked = OSAllocatedUnfairLock(initialState: true)
        let reading = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let outbox = SyncOutbox(directory: directory) { url in
            guard !locked.withLock({ $0 }) else { throw CocoaError(.fileReadNoPermission) }
            if !reading.withLock({ $0 }) {
                reading.withLock { $0 = true }
                release.wait()
            }
            return try Data(contentsOf: url)
        }
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]), outbox: outbox)
        let fetchedAt = Date()
        locked.withLock { $0 = false }

        let keys = Task { await coordinator.courseAddKeys(unlandedAt: fetchedAt) }
        try await waitUntil { reading.withLock { $0 } }
        let add = coordinator.addCourse(semester: "1151", courseNo: "GE1010001")
        release.signal()

        #expect(await keys.value == ["1151:GE1010001"])
        await add.value
    }

    @Test("Use Server for courses refuses an add still on its way into the outbox")
    func useServerRefusesAnAddOnItsWayIn() async {
        let backend = Backend()
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))

        let add = coordinator.addCourse(semester: "1151", courseNo: "GE1010001")
        await coordinator.discardEdits(of: ["courses"], courseIgnores: false)
        await add.value

        #expect(backend.uploads.isEmpty)
        #expect(!(await coordinator.holdsUnsentEdits()))
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()).isEmpty)
    }

    @Test("A reset made elsewhere wipes the hand-added and hidden courses but keeps those an add or hide made after it still sends")
    func resetElsewhereKeepsTheCoursesOfLaterEdits() async {
        let resetAt = Date().addingTimeInterval(-3600)
        let early = resetAt.addingTimeInterval(-CloudSyncCoordinator.clockSkewMargin - 60)
        let courses = ["GE1010001", "GE2", "GE3"].map { SDCourse(courseNo: $0, courseName: $0, semester: "1151") }
        let cache = Self.makeCache(userAdded: courses, hidden: ["1151:PE4", "1151:PE5", "1151:PE6"])
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE1010001", stamp: Date()))
        await outbox.enqueue(.courseAdd(semester: "1151", courseNo: "GE2", stamp: early))
        await outbox.enqueue(.courseDelete(semester: "1151", courseNo: "PE4", stamp: Date()))
        await outbox.enqueue(.courseDelete(semester: "1151", courseNo: "PE5", stamp: early))
        let coordinator = Self.makeCoordinator(Backend(), cache: cache, outbox: outbox)

        #expect(await AppState.applyCourseReset(at: resetAt, cache: cache, on: coordinator, mayWrite: { true }) == ["1151:PE5"])

        #expect(cache.loadUserAddedCourses().map(\.courseNo) == ["GE1010001"])
        #expect(cache.loadDeletedCourseNos() == ["1151:PE4"])
        #expect(AppState.addedCourseUpload(semester: "1151", courseNo: "GE1010001", cache: cache, colors: [:]) != nil)
    }

    @Test("A reset made elsewhere leaves the hand-added and hidden courses alone when the sync may no longer write, as behind the lock screen")
    func resetElsewhereWritesNothingWhenItMayNot() async {
        let cache = Self.makeCache(userAdded: [Self.art()], hidden: ["1151:PE4"])
        let coordinator = Self.makeCoordinator(Backend(), cache: cache)

        #expect(await AppState.applyCourseReset(at: Date(), cache: cache, on: coordinator, mayWrite: { false }) == nil)

        #expect(cache.loadUserAddedCourses().map(\.courseNo) == ["GE1010001"])
        #expect(cache.loadDeletedCourseNos() == ["1151:PE4"])
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

    @Test("A course a filled term's snapshot does not list goes, by tombstone, by absence or as hand-added, unless its add from here had not landed",
          arguments: [false, true])
    func unlistedCourseStaysWhileItsAddIsOut(adding: Bool) {
        let keys = adding
            ? ["1151:GE1010001", "1151:EE2005301", "1151:MA1010003"]
            : ["1142:GE1010001", "1142:EE2005301", "1142:MA1010003"]

        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: ["CS1001301"], tombstoned: ["GE1010001"], fetched: ["CS1001301", "EE2005301"],
            handAdded: ["MA1010003"], droppedMerges: [], hidden: [], adding: Set(keys)
        )

        #expect(unlisted.hide == (adding ? [] : ["GE1010001", "EE2005301"]))
        #expect(unlisted.drop == (adding ? [] : ["MA1010003"]))
    }

    @Test("An empty term's snapshot hides only by tombstone, and a course hidden already is not hidden again")
    func emptyTermHidesOnlyByTombstone() {
        let unlisted = AppState.unlistedCourses(
            in: "1151", listed: [], tombstoned: ["GE1010001", "PE1010002"], fetched: ["CS1001301"],
            handAdded: ["MA1010003"], droppedMerges: [], hidden: ["1151:PE1010002"], adding: []
        )

        #expect(unlisted.hide == ["GE1010001"])
        #expect(unlisted.drop.isEmpty)
    }

    @Test("An add the server keeps failing with 5xx spends its attempts and parks, so the ops behind it still go")
    func failingAddDoesNotHoldTheQueue() async {
        let backend = Backend()
        for _ in 0..<SyncOutbox.maxAttempts { backend.answer(503) }
        let deleteURL = backend.baseURL.appendingPathComponent("sync/courses/client:1151:CS1001301")
            .appending(queryItems: [URLQueryItem(name: "hlc", value: String(PushAPI.clock(of: Self.hiddenAt)))])
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"deleted": 1}"#.utf8)), for: deleteURL)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))

        await coordinator.addCourse(semester: "1151", courseNo: "GE1010001").value
        await coordinator.deleteCourse(semester: "1151", courseNo: "CS1001301", at: Self.hiddenAt)

        #expect(SettingsAPIStub.requests(for: deleteURL).count == 1)
        for _ in 2..<SyncOutbox.maxAttempts { await coordinator.syncTick() }
        #expect(backend.uploads.count == SyncOutbox.maxAttempts)
        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()) == ["1151:GE1010001"])
    }

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

    @Test("A course added back while its delete is being sent goes up once that delete has landed")
    func addGoesAfterAnInFlightDelete() async throws {
        let backend = Backend()
        let deleteURL = backend.baseURL.appendingPathComponent("sync/courses/client:1151:GE1010001")
            .appending(queryItems: [URLQueryItem(name: "hlc", value: String(PushAPI.clock(of: Self.hiddenAt)))])
        let gate = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(#"{"deleted": 1}"#.utf8), gate: gate), for: deleteURL)
        backend.answer(200)
        let coordinator = Self.makeCoordinator(backend, cache: Self.makeCache(userAdded: [Self.art()]))
        let delete = Task { await coordinator.deleteCourse(semester: "1151", courseNo: "GE1010001", at: Self.hiddenAt) }
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
