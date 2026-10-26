import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseDeleteSyncTests {
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()

        func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

        func requests(_ path: String) -> [URLRequest] { SettingsAPIStub.requests(for: url(path)) }

        func answer(_ path: String, _ response: SettingsAPIStub.StubResponse = .deleted) {
            SettingsAPIStub.enqueue(response, for: url(path))
        }
    }

    private static let path = "sync/courses/client:1151:CS1001301"

    private static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseDeleteSyncTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeCoordinator(
        _ backend: Backend, isEnabled: Bool = true, syncsCourseIgnores: @escaping @Sendable () -> Bool = { true }
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
            pushCoordinator: push, outbox: SyncOutbox(directory: Self.freshDirectory()), isEnabled: isEnabled,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: syncsCourseIgnores, syncsCourseOverrides: { _ in true }
        )
    }

    private static let colourReply = Data(
        ##"{"id":1,"color_hex":"#FF6B6B","custom_names":{},"updated_at":"2026-10-12T00:00:00+00:00"}"##.utf8
    )

    @Test("Deleting a course drops its own settings still queued, and queues its delete and sends it")
    func deletingACourseQueuesAndSendsItsDelete() async {
        let backend = Backend()
        backend.answer(Self.path)
        let coordinator = Self.makeCoordinator(backend, syncsCourseIgnores: { false })
        for courseNo in ["CS1001301", "EE2005301"] {
            await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: courseNo, moodleId: "1151\(courseNo)",
                                                  moodleCourseId: nil, ignore: true)
        }

        await coordinator.deleteCourse(semester: "1151", courseNo: "CS1001301")

        #expect(backend.requests(Self.path).map(\.httpMethod) == ["DELETE"])
        #expect(await coordinator.pendingCourseDeleteKeys().isEmpty)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:EE2005301"])
    }

    @Test("A delete queued while a drain is out goes once that drain ends")
    func deleteQueuedDuringADrainGoesAfterIt() async throws {
        let backend = Backend()
        let gate = SettingsAPIStub.ReplyGate()
        backend.answer("sync/courses/1151EE2005301/override", .init(statusCode: 200, body: Self.colourReply, gate: gate))
        backend.answer(Self.path)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseColorOverride(moodleId: "1151EE2005301", semester: "1151", colorHex: "#FF6B6B")?.value
        let drain = Task { await coordinator.syncTick() }
        try await waitUntil { !backend.requests("sync/courses/1151EE2005301/override").isEmpty }

        await coordinator.deleteCourse(semester: "1151", courseNo: "CS1001301")
        gate.open()
        await drain.value

        try await waitUntil(timeout: .seconds(10)) { backend.requests(Self.path).count == 1 }
    }

    @Test("A delete that lands while a snapshot is fetched counts for it, as does one queued meanwhile")
    func deletesQueuedAroundAFetchCount() async {
        let backend = Backend()
        backend.answer(Self.path)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "CS1001301")

        let (fetched, deleting) = await coordinator.courseDeletes(around: {
            await coordinator.syncTick()
            await coordinator.enqueueCourseDelete(semester: "1142", courseNo: "EE2005301")
            return "snapshot"
        })

        #expect(fetched == "snapshot")
        #expect(deleting == ["1151:CS1001301", "1142:EE2005301"])
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1142:EE2005301"])
    }

    @Test("A course hidden offline stays queued for its delete, which goes once the server answers")
    func offlineDeleteWaitsUntilItLands() async {
        let backend = Backend()
        backend.answer(Self.path, .noReply)
        backend.answer(Self.path)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "CS1001301")

        await coordinator.syncTick()

        #expect(backend.requests(Self.path).map(\.httpMethod) == ["DELETE"])
        #expect(await coordinator.outbox.snapshot().map(\.attempts) == [0])
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:CS1001301"])

        await coordinator.syncTick()

        #expect(backend.requests(Self.path).count == 2)
        #expect(await coordinator.pendingCourseDeleteKeys().isEmpty)
    }

    @Test("A queued delete survives a relaunch")
    func queuedDeleteSurvivesARelaunch() async throws {
        let directory = Self.freshDirectory()
        await SyncOutbox(directory: directory).enqueue(.courseDelete(semester: "1151", courseNo: "CS1001301", stamp: Date()))

        let op = try #require(await SyncOutbox(directory: directory).snapshot().first?.op)

        guard case let .courseDelete(semester, courseNo, _) = op else {
            Issue.record("decoded as \(op)")
            return
        }
        #expect(semester == "1151")
        #expect(courseNo == "CS1001301")
    }

    @Test("A delete the server keeps refusing is dropped, so the next full sync follows the server")
    func refusedDeleteIsDropped() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(.courseDelete(semester: "1151", courseNo: "CS1001301", stamp: Date()))

        for _ in 1..<SyncOutbox.maxAttempts {
            await outbox.drain { _ in throw PushAPIError.httpStatus(404, body: "") }
        }
        #expect(await outbox.pendingCount() == 1)

        await outbox.drain { _ in throw PushAPIError.httpStatus(404, body: "") }

        #expect(await outbox.pendingCount() == 0)
        #expect(await outbox.parkedSnapshot().isEmpty)
    }

    @Test("A course added back drops its own queued delete, and a reset its term's or every term's")
    func addingBackAndResetsDropTheirDeletes() async {
        let coordinator = Self.makeCoordinator(Backend())
        for key in ["1151:CS1", "1151:EE2", "1142:CS1", "1142:GE3"] {
            guard let (semester, courseNo) = CourseTombstone.parts(of: key) else { continue }
            await coordinator.enqueueCourseDelete(semester: semester, courseNo: courseNo)
        }
        await coordinator.enqueueCourseIgnore(semester: "1142", courseNo: "GE3", moodleId: "1142GE3",
                                              moodleCourseId: nil, ignore: true)

        await coordinator.discardCourseDeletes(courseKeys: ["client:1142:GE3"], madeBefore: Date())
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:CS1", "1151:EE2", "1142:CS1"])

        await coordinator.discardCourseDeletes(semester: "1151", madeBefore: Date())
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1142:CS1"])

        await coordinator.discardCourseDeletes(madeBefore: Date())
        #expect(await coordinator.pendingCourseDeleteKeys().isEmpty)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1142:GE3"])
    }

    @Test("A term reset drops the hides made while its request was out, which it clears here too, and keeps one made after it in both")
    func termResetAgreesWithItsLocalClear() async throws {
        let coordinator = Self.makeCoordinator(Backend())
        var hidden: Set<String> = []

        try await AppState.resetCourses(semester: "1151", on: coordinator, onServer: {
            hidden.insert("1151:CS1")
            await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "CS1", at: Date())
        }, thenLocally: { hidden.removeAll() })
        hidden.insert("1151:EE2")
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "EE2", at: Date())

        #expect(hidden == ["1151:EE2"])
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:EE2"])
    }

    @Test("Adding a course back drops its hides made before the re-add, but not one made after it while the drop was on its way")
    func reAddKeepsAHideMadeAfterIt() async {
        let coordinator = Self.makeCoordinator(Backend())
        let addedAt = Date().addingTimeInterval(-10)
        let hiddenAfter = Date().addingTimeInterval(-5)
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "CS1", at: addedAt.addingTimeInterval(-60))
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "EE2", at: hiddenAfter)

        await coordinator.discardCourseDeletes(courseKeys: ["client:1151:CS1", "client:1151:EE2", "client:1151:GE3"], madeBefore: addedAt)
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "GE3", at: hiddenAfter)

        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:EE2", "1151:GE3"])
    }

    @Test("A course hidden while TigerSync is on but before the coordinator has left disabled is queued for its delete")
    func hideDuringTheEnableWindowIsQueued() async {
        await withExclusiveRealDefaults {
            let saved = Defaults[.cloudSyncEnabled]
            defer { Defaults[.cloudSyncEnabled] = saved }
            let coordinator = Self.makeCoordinator(Backend(), isEnabled: false)

            Defaults[.cloudSyncEnabled] = false
            await coordinator.deleteCourse(semester: "1151", courseNo: "EE2005301")
            #expect(await coordinator.pendingCourseDeleteKeys().isEmpty)

            Defaults[.cloudSyncEnabled] = true
            await coordinator.deleteCourse(semester: "1151", courseNo: "CS1001301")
            #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:CS1001301"])
        }
    }

    @Test("A reset made elsewhere drops the course adds and deletes made here before it, one still on its way in too, and keeps those made after it or within the skew margin")
    func resetElsewhereDropsTheCourseEditsBeforeIt() async {
        let coordinator = Self.makeCoordinator(Backend())
        let reset = Date()
        let margin = CloudSyncCoordinator.clockSkewMargin
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "CS1", at: reset.addingTimeInterval(-margin - 60))
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "MA5", at: reset.addingTimeInterval(-margin + 60))
        await coordinator.enqueueCourseDelete(semester: "1142", courseNo: "EE2", at: reset.addingTimeInterval(60))
        await coordinator.outbox.enqueue(.courseAdd(
            semester: "1151", courseNo: "GE3", stamp: reset.addingTimeInterval(-margin - 60)
        ))
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1", moodleId: "1151CS1",
                                              moodleCourseId: nil, ignore: true)

        #expect(await coordinator.dropCourseEdits(madeBeforeReset: reset) == ["1151:CS1"])
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "PE4", at: reset.addingTimeInterval(-margin - 1))

        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:MA5", "1142:EE2"])
        #expect(await coordinator.courseAddKeys(unlandedAt: Date()).isEmpty)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:CS1"])
    }

    @Test("A full sync after a reset made elsewhere drops the deletes made here before the server's reset time, and keeps one made after it but before the sync")
    func fullSyncAfterAResetElsewhereDropsTheDeletesBeforeIt() async {
        let coordinator = Self.makeCoordinator(Backend())
        let resetAt = Date().addingTimeInterval(-3600)
        let margin = CloudSyncCoordinator.clockSkewMargin
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "CS1", at: resetAt.addingTimeInterval(-margin - 60))
        await coordinator.enqueueCourseDelete(semester: "1151", courseNo: "EE2", at: resetAt.addingTimeInterval(600))

        #expect(await coordinator.dropCourseEdits(madeBeforeReset: resetAt) == ["1151:CS1"])
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:EE2"])
    }

    @Test("A full sync shows a hidden course the server lists again only once no delete of it from here may be on its way")
    func listedCourseStaysHiddenWhileItsDeleteMayBeOnItsWay() {
        var hidden: Set<String> = ["1151:CS1", "1151:EE2", "1151:GE3", "PE4", "1142:MA5"]

        let changed = AppState.unhideListedCourses(
            ["CS1", "EE2", "GE3", "PE4", "MA5", "PH6"], semester: "1151", deleting: ["1151:EE2", "GE3", "1142:CS1"],
            in: &hidden
        )

        #expect(changed)
        #expect(hidden == ["1151:EE2", "1151:GE3", "1142:MA5"])
        #expect(!AppState.unhideListedCourses(["EE2"], semester: "1151", deleting: ["1151:EE2"], in: &hidden))
    }

    @Test("A full sync takes in a course only the server lists only once no delete of it from here may be on its way")
    func listedCourseIsMergedOnlyOnceNoDeleteIsOnItsWay() {
        let merges = { (courseNo: String) in
            AppState.mergesListedCourse(
                courseNo, semester: "1151", hidden: ["1151:GE3"], deleting: ["1151:CS1", "EE2", "1142:MA5"]
            )
        }

        #expect(!merges("CS1"))
        #expect(!merges("EE2"))
        #expect(!merges("GE3"))
        #expect(merges("MA5"))
        #expect(merges("PH6"))
    }

    @Test("Adding back a hidden course the class table still shows sends it with its key forced")
    func addingBackAStillShownHiddenCourseUploadsIt() {
        let savedHidden = DataCache.shared.loadDeletedCourseNos()
        defer { DataCache.shared.saveDeletedCourseNos(savedHidden) }
        let folder = Self.freshDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let viewModel = ClassTableViewModel(importedTables: ImportedClassTableStore(
            fileURL: folder.appendingPathComponent("imported_class_tables.json"), signedInStudentId: { "B11300000" }
        ))
        let course = SDCourse(courseNo: "GE1010001", courseName: "Art", semester: viewModel.currentSemester)
        viewModel.courses = [course]
        viewModel.deletedCourseNos = [CourseTombstone.key(semester: viewModel.currentSemester, courseNo: "GE1010001")]
        var added: [String] = []
        viewModel.onCourseAdded = { _, _, courseNo in added.append(courseNo) }

        #expect(!viewModel.addCourse(course))

        #expect(added == ["GE1010001"])
        #expect(viewModel.deletedCourseNos.isEmpty)
    }

    @Test("The courses re-enable check counts a course whose delete is queued as gone from the server")
    func queuedDeleteIsNoServerOnlyCourse() {
        let counts = { (deleting: Set<String>) in
            AppState.coursesOnOneSide(server: ["CS1", "EE2"], local: ["CS1", "GE3"], semester: "1151", deleting: deleting)
                .map { [$0.localOnly, $0.serverOnly] }
        }

        #expect(counts([]) == [1, 1])
        #expect(counts(["1151:EE2"]) == [1, 0])
        #expect(counts(["1142:EE2"]) == [1, 1])
        #expect(AppState.coursesOnOneSide(server: ["EE2"], local: ["CS1"], semester: "1151", deleting: ["1151:EE2"]) == nil)
        #expect(AppState.coursesOnOneSide(server: ["EE2"], local: [], semester: "1151", deleting: []) == nil)
    }

    @Test("A course whose delete is queued keeps this device's setting through a pull, in its own term only")
    func queuedDeleteKeepsTheLocalSetting() {
        let left = AppState.courseKeysPullLeaves(
            ["1151:CS1", "1142:CS1", "1151:EE2"], deleting: ["1151:CS1", "EE2"], resetSemesters: []
        )

        #expect(left == ["1151:CS1", "1151:EE2"])
    }
}

private extension SettingsAPIStub.StubResponse {
    static var deleted: Self { .init(statusCode: 200, body: Data(#"{"deleted": 1}"#.utf8)) }
}
