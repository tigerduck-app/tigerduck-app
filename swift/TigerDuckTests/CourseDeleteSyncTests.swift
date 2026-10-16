// Hiding a course deletes it on the server through the outbox
// (https://github.com/tigerduck-app/tigerduck-app/issues/666): the delete waits there until it
// lands, and a full sync keeps the course hidden here as long.
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
        _ backend: Backend, syncsCourseIgnores: @escaping @Sendable () -> Bool = { true }
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
            pushCoordinator: push, outbox: SyncOutbox(directory: Self.freshDirectory()), isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: syncsCourseIgnores
        )
    }

    private static let colourReply = Data(
        ##"{"id":1,"color_hex":"#FF6B6B","custom_names":{},"updated_at":"2026-10-12T00:00:00+00:00"}"##.utf8
    )

    /// What hiding a course does, through `AppState.deleteBackendCourse`.
    @Test("Deleting a course drops its own settings still queued, and queues its delete and sends it")
    func deletingACourseQueuesAndSendsItsDelete() async {
        let backend = Backend()
        backend.answer(Self.path)
        // The settings wait, so the tick sends the delete alone.
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

    /// What a full sync and the re-enable check read for the snapshot they fetch.
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

        for _ in 0..<SyncOutbox.maxAttempts {
            await outbox.drain { _ in throw PushAPIError.httpStatus(404, body: "") }
        }

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

        await coordinator.discardCourseDeletes(courseKeys: ["client:1142:GE3"])
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1151:CS1", "1151:EE2", "1142:CS1"])

        await coordinator.discardCourseDeletes(semester: "1151")
        #expect(await coordinator.pendingCourseDeleteKeys() == ["1142:CS1"])

        await coordinator.discardCourseDeletes()
        #expect(await coordinator.pendingCourseDeleteKeys().isEmpty)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1142:GE3"])
    }

    /// `deleting` holds the course numbers deleted here within the grace window and the keys of
    /// the deletes still queued. A legacy bare entry hides its course in every term.
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
