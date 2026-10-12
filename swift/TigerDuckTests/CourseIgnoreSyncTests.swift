// Syncing a course's "ignore assignments" setting
// (https://github.com/tigerduck-app/tigerduck-backend/pull/33): the outbox op that sends it, and
// what a full sync does with the server's copy.
import Foundation
import Testing
import os
@testable import TigerDuck

struct CourseIgnoreOutboxTests {
    private static func freshDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseIgnoreOutboxTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func setting(_ ignore: Bool?, moodleCourseId: Int? = 4242) -> SyncOp {
        .courseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                      moodleCourseId: moodleCourseId, ignore: ignore, stamp: Date())
    }

    @Test("A queued setting survives a relaunch with all it carries")
    func queuedSettingSurvivesARelaunch() async throws {
        let directory = Self.freshDirectory()
        await SyncOutbox(directory: directory).enqueue(Self.setting(true))

        let op = try #require(await SyncOutbox(directory: directory).snapshot().first?.op)

        guard case let .courseIgnore(semester, courseNo, moodleId, moodleCourseId, ignore, _) = op else {
            Issue.record("decoded as \(op)")
            return
        }
        #expect(semester == "1151")
        #expect(courseNo == "CS1001301")
        #expect(moodleId == "1151CS1001301")
        #expect(moodleCourseId == 4242)
        #expect(ignore == true)
    }

    @Test("A newer setting for the course replaces the queued one")
    func newerSettingReplacesTheQueuedOne() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(Self.setting(true))
        await outbox.enqueue(Self.setting(false))

        let ops = await outbox.snapshot().map(\.op)
        #expect(ops.count == 1)
        if case .courseIgnore(_, _, _, _, let ignore, _) = ops.first {
            #expect(ignore == false)
        }
    }

    @Test("A setting the server keeps refusing is parked, and a numeric id sent alone is dropped")
    func refusedSettingIsParkedAndALoneIdDropped() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(Self.setting(true))
        await outbox.enqueue(.courseIgnore(semester: "1151", courseNo: "EE2005301", moodleId: "1151EE2005301",
                                           moodleCourseId: 77, ignore: nil, stamp: Date()))

        for _ in 0..<SyncOutbox.maxAttempts {
            await outbox.drain { _ in throw PushAPIError.httpStatus(404, body: "") }
        }

        #expect(await outbox.pendingCount() == 0)
        #expect(await outbox.parkedSnapshot().map(\.op.dedupKey) == [Self.setting(true).dedupKey])
    }

    private static let isSetting: @Sendable (SyncOp) -> Bool = { op in
        if case .courseIgnore = op { return true }
        return false
    }

    private static let colour = SyncOp.courseOverride(
        semester: "1151", moodleId: "1151EE2005301", customName: nil, colorHex: "#FF6B6B",
        locale: nil, stamp: Date())

    @Test("Discarding the settings drops the queued and parked ones and keeps every other edit")
    func discardDropsOnlyTheSettings() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(Self.setting(true))
        for _ in 0..<SyncOutbox.maxAttempts {
            await outbox.drain { _ in throw PushAPIError.httpStatus(404, body: "") }
        }
        await outbox.enqueue(.courseIgnore(semester: "1151", courseNo: "EE2005301", moodleId: "1151EE2005301",
                                           moodleCourseId: nil, ignore: false, stamp: Date()))
        await outbox.enqueue(Self.colour)

        await outbox.discard(where: Self.isSetting)

        #expect(await outbox.snapshot().map(\.op.dedupKey) == [Self.colour.dedupKey])
        #expect(await outbox.parkedSnapshot().isEmpty)
    }

    @Test("A drain under way does not send a setting discarded before its turn")
    func drainSkipsASettingDiscardedBeforeItsTurn() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(Self.colour)
        await outbox.enqueue(Self.setting(true))
        let sent = Sent()

        await outbox.drain { op in
            await sent.add(op)
            await outbox.discard(where: Self.isSetting)
        }

        #expect(await sent.count == 1)
        #expect(await outbox.snapshot().isEmpty)
    }

    private actor Sent {
        private(set) var count = 0
        func add(_ op: ResolvedSyncOp) { count += 1 }
    }

    @Test("A drain under way neither keeps nor parks a setting discarded while it ran")
    func drainDoesNotBringADiscardedSettingBack() async {
        let outbox = SyncOutbox(directory: Self.freshDirectory())
        await outbox.enqueue(Self.setting(true))
        await outbox.enqueue(Self.colour)

        // Refused once, then discarded while the colour's request is out: no copy is kept.
        await outbox.drain { op in
            if case .courseIgnore = op { throw PushAPIError.httpStatus(404, body: "") }
            await outbox.discard(where: Self.isSetting)
        }
        #expect(await outbox.snapshot().isEmpty)

        // Discarded while its own request is out, on the attempt that would park it.
        await outbox.enqueue(Self.setting(true))
        for _ in 0..<(SyncOutbox.maxAttempts - 1) {
            await outbox.drain { _ in throw PushAPIError.httpStatus(404, body: "") }
        }
        await outbox.drain { _ in
            await outbox.discard(where: Self.isSetting)
            throw PushAPIError.httpStatus(404, body: "")
        }
        #expect(await outbox.snapshot().isEmpty)
        #expect(await outbox.parkedSnapshot().isEmpty)
    }
}

@MainActor
struct CourseIgnoreCoordinatorTests {
    private struct Backend {
        let baseURL = SettingsAPIStub.uniqueBaseURL()

        func url(_ path: String) -> URL { baseURL.appendingPathComponent(path) }

        func bodies(_ path: String) -> [[String: Any]] {
            SettingsAPIStub.requests(for: url(path)).compactMap { request in
                SettingsAPIStub.bodyData(from: request)
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            }
        }

        func answer(_ path: String, status: Int = 200) {
            let body = #"{"id":1,"color_hex":null,"custom_names":{},"ignore_assignments":true,"updated_at":"2026-10-13T00:00:00+00:00"}"#
            SettingsAPIStub.enqueue(.init(statusCode: status, body: Data(body.utf8)), for: url(path))
        }

        /// The answer of a backend that predates the setting and drops it from the request.
        func answerWithoutTheSetting(_ path: String) {
            let body = #"{"id":1,"color_hex":null,"custom_names":{},"updated_at":"2026-10-13T00:00:00+00:00"}"#
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data(body.utf8)), for: url(path))
        }
    }

    private static let path = "sync/courses/1151CS1001301/override"

    private static func makeCoordinator(
        _ backend: Backend,
        syncsAssignmentMarks: @escaping @Sendable () -> Bool = { true },
        syncsCourseIgnores: @escaping @Sendable () -> Bool = { true }
    ) -> CloudSyncCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { [baseURL = backend.baseURL] in baseURL },
            session: URLSession(configuration: config)
        )
        let push = PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseIgnoreCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        return CloudSyncCoordinator(
            pushCoordinator: push, outbox: SyncOutbox(directory: directory), isEnabled: true,
            syncsAssignmentMarks: syncsAssignmentMarks, syncsCourseIgnores: syncsCourseIgnores
        )
    }

    @Test("The setting goes up with the course's numeric Moodle id, by the course's idnumber")
    func settingIsPatchedWithTheNumericId() async throws {
        let backend = Backend()
        backend.answer(Self.path)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: 4242, ignore: true)

        await coordinator.syncTick()

        let body = try #require(backend.bodies(Self.path).first)
        #expect(body["ignore_assignments"] as? Bool == true)
        #expect(body["moodle_course_id"] as? Int == 4242)
        #expect(Set(body.keys) == ["ignore_assignments", "moodle_course_id"])
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("A numeric id sent alone carries no setting")
    func loneIdCarriesNoSetting() async throws {
        let backend = Backend()
        backend.answer(Self.path)
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: 4242, ignore: nil)

        await coordinator.syncTick()

        let body = try #require(backend.bodies(Self.path).first)
        #expect(Set(body.keys) == ["moodle_course_id"])
    }

    @Test("With the Courses switch off the setting waits, though the marks go, until both switches are on")
    func coursesSwitchOffHoldsTheSetting() async {
        let backend = Backend()
        backend.answer(Self.path)
        let syncsIgnores = OSAllocatedUnfairLock(initialState: false)
        let coordinator = Self.makeCoordinator(
            backend, syncsAssignmentMarks: { true }, syncsCourseIgnores: { syncsIgnores.withLock { $0 } }
        )
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: nil, ignore: true)

        await coordinator.syncTick()
        #expect(backend.bodies(Self.path).isEmpty)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:CS1001301"])

        syncsIgnores.withLock { $0 = true }
        await coordinator.syncTick()
        #expect(backend.bodies(Self.path).count == 1)
        #expect(await coordinator.pendingCourseIgnoreKeys().isEmpty)
    }

    @Test("A setting goes out only with both switches on and the re-enabled Assignments switch's check settled")
    func settingsGoOutWithBothSwitchesOnAndNoCheckPending() {
        #expect(CloudSyncCoordinator.sendsCourseIgnores(assignments: true, courses: true, pendingChecks: ["courses"]))
        #expect(!CloudSyncCoordinator.sendsCourseIgnores(assignments: true, courses: false, pendingChecks: []))
        #expect(!CloudSyncCoordinator.sendsCourseIgnores(assignments: false, courses: true, pendingChecks: []))
        #expect(!CloudSyncCoordinator.sendsCourseIgnores(assignments: true, courses: true, pendingChecks: ["assignments"]))
    }

    @Test("An answer without the setting, from a backend that predates it, is a refusal and parks it after five")
    func answerWithoutTheSettingIsARefusal() async {
        let backend = Backend()
        for _ in 0..<SyncOutbox.maxAttempts { backend.answerWithoutTheSetting(Self.path) }
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: nil, ignore: true)

        await coordinator.syncTick()
        #expect(await coordinator.outbox.snapshot().map(\.attempts) == [1])

        for _ in 1..<SyncOutbox.maxAttempts { await coordinator.syncTick() }
        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.outbox.parkedSnapshot().count == 1)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:CS1001301"])
    }

    @Test("A setting still on its way up counts as pending, parked or not; a lone id does not")
    func pendingKeysCoverSettingsOnly() async {
        let backend = Backend()
        for _ in 0..<SyncOutbox.maxAttempts {
            backend.answer(Self.path, status: 404)
            backend.answer("sync/courses/1151EE2005301/override", status: 404)
        }
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: nil, ignore: true)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "EE2005301", moodleId: "1151EE2005301",
                                              moodleCourseId: 77, ignore: nil)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:CS1001301"])

        for _ in 0..<SyncOutbox.maxAttempts { await coordinator.syncTick() }

        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:CS1001301"])
    }
}

extension CourseIgnoreCoordinatorTests {
    @Test("Use Server drops the settings still waiting to go up, and leaves the marks")
    func useServerDropsWaitingSettings() async {
        let coordinator = Self.makeCoordinator(
            Backend(), syncsAssignmentMarks: { false }, syncsCourseIgnores: { false }
        )
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: nil, ignore: true)
        await coordinator.enqueueAssignmentOverride(moodleCourseId: 0, moodleAssignmentId: 42, localStatus: "ignored")

        await coordinator.discardCourseIgnores()

        #expect(await coordinator.pendingCourseIgnoreKeys().isEmpty)
        #expect(await coordinator.pendingAssignmentOverrideIds() == ["42"])
    }

    @Test("Deleting a course drops its settings still on their way up, parked too, and a reset its term's")
    func deleteAndResetDropTheirSettings() async {
        let backend = Backend()
        for _ in 0..<SyncOutbox.maxAttempts { backend.answer(Self.path, status: 404) }
        let coordinator = Self.makeCoordinator(backend)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                              moodleCourseId: nil, ignore: true)
        for _ in 0..<SyncOutbox.maxAttempts { await coordinator.syncTick() }
        #expect(await coordinator.outbox.parkedSnapshot().count == 1)
        await coordinator.enqueueCourseIgnore(semester: "1151", courseNo: "EE2005301", moodleId: "1151EE2005301",
                                              moodleCourseId: nil, ignore: false)
        await coordinator.enqueueCourseIgnore(semester: "1142", courseNo: "CS1001301", moodleId: "1142CS1001301",
                                              moodleCourseId: nil, ignore: true)

        await coordinator.discardCourseIgnores(semester: "1151", courseNo: "CS1001301")
        #expect(await coordinator.outbox.parkedSnapshot().isEmpty)
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1151:EE2005301", "1142:CS1001301"])

        await coordinator.discardCourseIgnores(semester: "1151")
        #expect(await coordinator.pendingCourseIgnoreKeys() == ["1142:CS1001301"])
    }
}

/// What a full sync reads from the snapshot's `course_overrides` (`AppState+BackendSync.swift`).
@MainActor
struct CourseIgnorePullTests {
    /// A row of `course_overrides`; `setAt` is when a device last set the course's setting.
    private static func row(
        _ courseNo: String, semester: String = "1151", ignored: Bool? = true, setAt: String? = nil,
        moodleCourseId: Int? = nil
    ) -> [String: Any] {
        var row: [String: Any] = [
            "course_no": courseNo, "semester": semester, "moodle_id": "\(semester)\(courseNo)",
            "moodle_course_id": moodleCourseId.map { $0 as Any } ?? NSNull(),
        ]
        if let ignored {
            row["ignore_assignments"] = ignored
            row["ignore_assignments_updated_at"] = setAt.map { $0 as Any } ?? NSNull()
        }
        return row
    }

    @Test("A backend without the setting is read as having none to apply")
    func oldBackendIsSkipped() {
        #expect(AppState.serverIgnoredCourses([Self.row("CS1"), Self.row("EE2", ignored: nil)], syncsCourses: true) == nil)
    }

    @Test("With the Courses switch off a pull and the re-enable check take no course settings")
    func coursesSwitchOffTakesNone() {
        #expect(AppState.serverIgnoredCourses([Self.row("CS1")], syncsCourses: false) == nil)
    }

    @Test("The server's ignored courses are keyed by term and course number")
    func serverRowsAreKeyed() throws {
        let courses = try #require(AppState.serverIgnoredCourses([
            Self.row("CS1", moodleCourseId: 4242), Self.row("EE2", ignored: false), Self.row("GE3", semester: ""),
        ], syncsCourses: true))
        #expect(courses == [AppState.ServerIgnoredCourse(
            semester: "1151", courseNo: "CS1", moodleId: "1151CS1", moodleCourseId: 4242
        )])
    }

    @Test("A term the snapshot has courses in takes the server's setting")
    func coveredTermsFollowTheServer() {
        let merged = AppState.mergedIgnoredCourses(
            server: ["1151:CS1"], local: ["1151:EE2"], protected: [], snapshotSemesters: ["1151"]
        )
        #expect(merged == ["1151:CS1"])
    }

    @Test("A setting not on the server yet keeps this device's, set or cleared")
    func pendingSettingsKeepTheLocalOne() {
        let merged = AppState.mergedIgnoredCourses(
            server: ["1151:CS1"], local: ["1151:EE2"], protected: ["1151:CS1", "1151:EE2"],
            snapshotSemesters: ["1151"]
        )
        #expect(merged == ["1151:EE2"])
    }

    @Test("A term the snapshot has no courses in is left as it is here")
    func uncoveredTermsAreLeftAlone() {
        let merged = AppState.mergedIgnoredCourses(
            server: [], local: ["1142:CS1", "1151:EE2"], protected: [], snapshotSemesters: ["1151"]
        )
        #expect(merged == ["1142:CS1"])
    }

    @Test("The re-enabled switch's check finds a difference only where a pull would apply one")
    func reenableCheckComparesCoveredTerms() {
        let differ = { (server: Set<String>?, decided: Set<String>, local: Set<String>) in
            AppState.ignoredCoursesDiffer(
                server: server, decided: decided, listed: ["1151:CS1"], local: local, snapshotSemesters: ["1151"]
            )
        }
        #expect(differ(["1151:CS1"], ["1151:CS1"], []))
        #expect(differ([], ["1151:CS1"], ["1151:CS1"]))
        #expect(!differ([], [], ["1142:CS1"]))
        #expect(!differ(nil, [], ["1151:CS1"]))
        // The server lost it: a pull keeps it and sends it again.
        #expect(!differ([], [], ["1151:CS1"]))
    }

    @Test("A course's setting counts as set on the server once a device has sent it, either way")
    func decidedCoursesAreTheOnesSent() {
        let decided = AppState.serverDecidedCourses([
            Self.row("CS1", setAt: "2026-10-13T00:00:00+00:00"),
            Self.row("EE2", ignored: false, setAt: "2026-10-13T00:00:00+00:00"),
            Self.row("GE3", ignored: false),
            Self.row("PE4", ignored: nil),
        ])
        #expect(decided == ["1151:CS1", "1151:EE2"])
    }

    @Test("The snapshot's courses are keyed by term and course number, its own Moodle rows left out")
    func listedCoursesAreKeyed() {
        let listed = AppState.listedCourses([
            ["semester": "1151", "course_no": "CS1"], ["semester": "", "course_no": "EE2"], ["semester": "1142"],
        ])
        #expect(listed == ["1151:CS1"])
    }

    @Test("A setting the server lost with its course rows stays and goes up again; one it holds does not")
    func lostSettingsStayAndGoUpAgain() {
        let pull = AppState.ignoredCoursesAfterPull(
            server: [], decided: ["1151:EE2"], listed: ["1151:CS1", "1151:EE2", "1151:PE4"],
            local: ["1151:CS1", "1151:EE2", "1151:GE3", "1151:PE4"], protected: ["1151:PE4"],
            snapshotSemesters: ["1151"]
        )
        // CS1 the server lost; EE2 another device stopped ignoring; GE3 is gone from the server;
        // PE4 is on its way up already.
        #expect(pull.ignored == ["1151:CS1", "1151:PE4"])
        #expect(pull.resend == ["1151:CS1"])
    }

    @Test("A course being deleted here and a term reset since the snapshot keep this device's setting")
    func deletingCoursesAndResetTermsKeepTheLocalSetting() {
        let left = AppState.courseKeysPullLeaves(
            ["1151:CS1", "1151:EE2", "1142:GE3", "1142:PE4"], deleting: ["CS1"], resetSemesters: ["1142"]
        )
        #expect(left == ["1151:CS1", "1142:GE3", "1142:PE4"])

        let pull = AppState.ignoredCoursesAfterPull(
            server: ["1151:CS1", "1151:EE2", "1142:GE3"], decided: ["1151:CS1", "1151:EE2", "1142:GE3"],
            listed: ["1151:CS1", "1151:EE2", "1142:GE3", "1142:PE4"], local: ["1142:PE4"],
            protected: left, snapshotSemesters: ["1151", "1142"]
        )
        // EE2 stands for a course hidden here that another device added back: it is not being
        // deleted here, so its setting applies.
        #expect(pull.ignored == ["1151:EE2", "1142:PE4"])
        #expect(pull.resend.isEmpty)
    }

    @Test("The numeric id goes up for an ignored course the server has none for, once this device knows it")
    func missingNumericIdsAreSent() throws {
        let courses = try #require(AppState.serverIgnoredCourses([
            Self.row("CS1"), Self.row("EE2", moodleCourseId: 77), Self.row("GE3"), Self.row("PE4"),
        ], syncsCourses: true))

        let toSend = AppState.moodleCourseIdsToSend(courses, protected: ["1151:PE4"]) { moodleId in
            ["1151CS1": 4242, "1151EE2": 77, "1151PE4": 9].first { $0.key == moodleId }?.value
        }

        #expect(toSend.map { $0.moodleId } == ["1151CS1"])
        #expect(toSend.map { $0.moodleCourseId } == [4242])
    }

    @Test("Keep Local stops ignoring on the server what this device does not ignore")
    func keepLocalClearsServerOnlySettings() throws {
        let server = try #require(AppState.serverIgnoredCourses([Self.row("CS1"), Self.row("EE2")], syncsCourses: true))

        let cleared = AppState.courseIgnoresToClear(server: server, local: ["1151:CS1", "1142:GE3"])

        #expect(cleared.map(\.key) == ["1151:EE2"])
    }
}
