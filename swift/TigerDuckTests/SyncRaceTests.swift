import Foundation
import Testing
@testable import TigerDuck

/// The interleavings of a send with an edit, a reply or a sign-out that once lost an edit, each
/// driven here in the order that lost it.
@MainActor
struct SyncRaceTests {
    @MainActor
    private final class Asked {
        var value = false
    }

    private static let red: UInt32 = 0xFF6B6B
    private static let teal: UInt32 = 0x4ECDC4

    private static func stubSession(timeout: TimeInterval = 600) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        config.timeoutIntervalForRequest = timeout
        return URLSession(configuration: config)
    }

    private static func push(_ baseURL: URL) -> PushCoordinator {
        let client = PushAPIClient(baseURLProvider: { baseURL }, session: stubSession(), authHeaderProvider: { "Bearer test" })
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
    }

    private static func cache() -> TestCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyncRaceTests-\(UUID().uuidString)", isDirectory: true)
        let cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        cache.courses.saveCourses([
            SDCourse(courseNo: "CS1", courseName: "CS1", moodleIdNumber: "1151CS1", semester: "1151"),
            SDCourse(courseNo: "CS2", courseName: "CS2", moodleIdNumber: "1151CS2", semester: "1151"),
        ], semester: "1151")
        return cache
    }

    private static func policy(_ switchedOn: Set<String>) -> @MainActor () -> SyncPolicy {
        { SyncPolicy(cloudSyncEnabled: true, switchedOn: switchedOn, pendingChecks: []) }
    }

    private static func sender(
        _ baseURL: URL, cache: TestCache, colors: CourseColorStore, switchedOn: Set<String>
    ) -> OutboxSender {
        OutboxSender(
            push: push(baseURL), addedCourseUpload: { _, _ in nil }, uploadsCourses: { true },
            isProtectedDataAvailable: { true }, account: AccountSession(), courses: cache.courses,
            kept: KeptValues(
                policy: policy(switchedOn), colors: colors, courses: cache.courses, assignments: cache.assignments
            )
        )
    }

    private static let colourEdit = SyncOp.courseOverride(
        semester: "1151", moodleId: "1151CS1", customName: nil, colorHex: "#4ECDC4", locale: nil,
        stamp: Date(timeIntervalSince1970: 1_790_000_000)
    )

    private static func keptRed(_ baseURL: URL) {
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(##"{"color_hex":"#FF6B6B","custom_names":{},"applied":[]}"##.utf8)),
            for: baseURL.appendingPathComponent("sync/courses/client:1151:CS1/override")
        )
    }

    // MARK: - R1

    @Test("A colour the backend kept over an older edit from here is applied by the colour store, which moves the course that held it")
    func keptColourGoesThroughTheColourStore() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let cache = Self.cache()
        let colors = CourseColorStore(files: cache.colors)
        colors.applyColors([("CS1", Self.teal), ("CS2", Self.red)], palette: TigerDuckTheme.coursePaletteHexes)
        Self.keptRed(baseURL)

        try await Self.sender(baseURL, cache: cache, colors: colors, switchedOn: ["courses", "course_colors"])
            .send(Self.colourEdit, newerQueued: { _ in false })

        #expect(colors.map["CS1"] == Self.red)
        #expect(colors.map["CS2"] != Self.red)
        #expect(colors.map["CS2"] != nil)
    }

    @Test("A kept colour is not applied over a newer edit queued here, or with colour sync off")
    func keptColourYieldsToANewerEditAndTheSwitch() async throws {
        for (newer, switchedOn) in [(true, Set(["courses", "course_colors"])), (false, Set(["courses"]))] {
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let cache = Self.cache()
            let colors = CourseColorStore(files: cache.colors)
            colors.applyColors([("CS1", Self.teal), ("CS2", Self.red)], palette: TigerDuckTheme.coursePaletteHexes)
            Self.keptRed(baseURL)

            try await Self.sender(baseURL, cache: cache, colors: colors, switchedOn: switchedOn)
                .send(Self.colourEdit, newerQueued: { _ in newer })

            #expect(colors.map == ["CS1": Self.teal, "CS2": Self.red])
        }
    }

    @Test("A mark the backend kept over an older one from here replaces it in the assignment store")
    func keptMarkGoesThroughTheAssignmentStore() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let cache = Self.cache()
        cache.assignments.replaceArchivedAssignmentIds(["42"])
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"local_status":"locally_completed","local_status_hlc":2,"applied":false}"#.utf8)),
            for: baseURL.appendingPathComponent("sync/assignments/42/override")
        )
        let op = SyncOp.assignmentOverride(
            moodleCourseId: 7, moodleAssignmentId: 42, localStatus: "ignored", stamp: Date(timeIntervalSince1970: 1_790_000_000)
        )

        try await Self.sender(baseURL, cache: cache, colors: CourseColorStore(files: cache.colors), switchedOn: ["assignments"])
            .send(op, newerQueued: { _ in false })

        #expect(cache.assignments.loadArchivedAssignmentIds().isEmpty)
        #expect(cache.assignments.loadLocallyCompletedAssignmentIds() == ["42"])
    }

    // MARK: - R3

    @Test("A colour for a course the backend does not hold yet waits parked, and goes once a course upload lands")
    func colourBeforeItsCourseWaitsForTheUpload() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("sync/courses/client:1151:CS1/override")
        SettingsAPIStub.enqueue(
            .init(statusCode: 404, body: Data(#"{"error":"course_not_found","message":"no course"}"#.utf8)), for: url
        )
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(##"{"color_hex":"#4ECDC4","applied":["color_hex"]}"##.utf8)), for: url
        )
        let cache = Self.cache()
        let coordinator = CloudSyncCoordinator(
            pushCoordinator: Self.push(baseURL),
            outbox: SyncOutbox(directory: cache.persistentDir.appendingPathComponent("outbox", isDirectory: true)),
            isEnabled: true, syncsAssignmentMarks: { true }, syncsCourseIgnores: { true },
            syncsCourseOverrides: { _ in true }, courses: cache.courses,
            kept: KeptValues(policy: Self.policy([]), colors: CourseColorStore(files: cache.colors),
                             courses: cache.courses, assignments: cache.assignments)
        )

        await coordinator.outbox.enqueue(Self.colourEdit)
        await coordinator.syncTick()
        #expect(SettingsAPIStub.requests(for: url).count == 1)
        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.outbox.parkedSnapshot().count == 1)
        await coordinator.syncTick()
        #expect(SettingsAPIStub.requests(for: url).count == 1)

        coordinator.courseUploadLanded()

        try await waitUntil { SettingsAPIStub.requests(for: url).count == 2 }
        var settled = false
        for _ in 0..<500 where !settled {
            let parked = await coordinator.outbox.parkedSnapshot().count
            let queued = await coordinator.outbox.pendingCount()
            settled = parked == 0 && queued == 0
            if !settled { try await Task.sleep(for: .milliseconds(20)) }
        }
        #expect(settled)
    }

    @Test("An ignore setting for a course the backend does not hold yet waits parked like a colour")
    func ignoreBeforeItsCourseWaitsForTheUpload() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("sync/courses/client:1151:CS1/override")
        SettingsAPIStub.enqueue(
            .init(statusCode: 404, body: Data(#"{"error":"course_not_found","message":"no course"}"#.utf8)), for: url
        )
        let cache = Self.cache()
        let coordinator = CloudSyncCoordinator(
            pushCoordinator: Self.push(baseURL),
            outbox: SyncOutbox(directory: cache.persistentDir.appendingPathComponent("outbox", isDirectory: true)),
            isEnabled: true, syncsAssignmentMarks: { true }, syncsCourseIgnores: { true },
            syncsCourseOverrides: { _ in true }, courses: cache.courses,
            kept: KeptValues(policy: Self.policy([]), colors: CourseColorStore(files: cache.colors),
                             courses: cache.courses, assignments: cache.assignments)
        )

        await coordinator.outbox.enqueue(.courseIgnore(
            semester: "1151", courseNo: "CS1", moodleId: "1151CS1", moodleCourseId: 4242, ignore: true,
            stamp: Date(timeIntervalSince1970: 1_790_000_000)
        ))
        await coordinator.syncTick()

        #expect(SettingsAPIStub.requests(for: url).count == 1)
        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(await coordinator.outbox.parkedSnapshot().map(\.op.dedupKey) == ["ci|1151|1151CS1"])
    }

    // MARK: - R4

    @Test("A rule edited while the save before it is out stays on screen and goes in the next save")
    func editDuringASaveIsSavedNext() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("bulletin-subscriptions")
        let first = SettingsAPIStub.ReplyGate()
        let rule = BulletinAPI.SubscriptionRule(name: "A")
        var edited = rule
        edited.name = "B"
        func reply(_ rule: BulletinAPI.SubscriptionRule, id: Int) -> Data {
            Data(#"{"items":[{"id":\#(id),"client_id":"\#(rule.clientId.uuidString)","name":"\#(rule.name ?? "")","orgs":[],"tags":[],"mode":"AND","enabled":true}]}"#.utf8)
        }
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: reply(rule, id: 1), gate: first), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: reply(edited, id: 1)), for: url)
        let store = BulletinSubscriptionsStore(
            apiClient: BulletinAPIClient(baseURLProvider: { baseURL }, session: Self.stubSession(), authHeaderProvider: { "Bearer test" }),
            retryDelay: { _ in }
        )

        store.upsert(rule)
        let save = Task { await store.save() }
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 1 }
        store.upsert(edited)
        let secondAsked = Asked()
        let second = Task {
            secondAsked.value = true
            await store.save()
        }
        try await waitUntil { secondAsked.value }
        try await Task.sleep(for: .milliseconds(200))
        #expect(SettingsAPIStub.requests(for: url).count == 1)
        first.open()
        await save.value
        await second.value

        let names = try SettingsAPIStub.requests(for: url).map { request in
            let body = try #require(SettingsAPIStub.bodyData(from: request))
            let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            return (json["rules"] as? [[String: Any]])?.first?["name"] as? String
        }
        #expect(names == ["A", "B"])
        #expect(store.pending.map(\.name) == ["B"])
        #expect(store.pending.map(\.clientId) == [rule.clientId])
        #expect(store.saveState == .saved)
    }

    // MARK: - R10

    private static func inputs(dueIn hours: Double, id: String) -> ScheduleSyncService.Inputs {
        let due = SDAssignment(
            assignmentId: id, courseNo: "CS101", courseName: "Algorithms", title: "Lab",
            dueDate: Date().addingTimeInterval(hours * 3600)
        )
        return ScheduleSyncService.Inputs(
            courses: [], assignments: [due], accentHex: 0x007AFF, classPreparingLeadTime: 0,
            assignmentLeadTime: 3600, showClassPreparing: false, showInClass: false, showAssignmentScenario: true,
            liveActivityAvailable: true, term: "1151"
        )
    }

    @Test("A newer schedule waits for the one still out, which it does not cancel, so the newer one lands last")
    func newerScheduleWaitsForTheOneOut() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("schedule/sync")
        let held = SettingsAPIStub.ReplyGate()
        let ok = Data(#"{"pending":1,"replaced":0}"#.utf8)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: ok, gate: held), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: ok), for: url)
        let push = Self.push(baseURL)
        let (olderID, newerID) = ("a-\(UUID().uuidString)", "a-\(UUID().uuidString)")
        let older = Self.inputs(dueIn: 3, id: olderID)
        let newer = Self.inputs(dueIn: 4, id: newerID)

        push.scheduleSync.sync(inputs: older)
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 1 }
        push.scheduleSync.sync(inputs: newer)
        for _ in 0..<50 { await Task.yield() }
        #expect(SettingsAPIStub.requests(for: url).count == 1)
        held.open()
        await push.scheduleSync.awaitInflight()

        let sent = SettingsAPIStub.requests(for: url).compactMap(SettingsAPIStub.bodyData(from:))
            .map { String(decoding: $0, as: UTF8.self) }
        #expect(sent.count == 2)
        #expect(sent.first?.contains(olderID) == true)
        #expect(sent.last?.contains(newerID) == true)
    }

    // MARK: - R11

    @Test("Keeping the server's side of a conflict reads the server again, and a sign-out meanwhile writes nothing")
    func keepingTheServerSideReadsItAgain() async {
        let cache = Self.cache()
        cache.assignments.replaceArchivedAssignmentIds(["1"])
        cache.assignments.replaceLocallyCompletedAssignmentIds([])

        await AssignmentMarksReconciler.keepServerSide(
            read: { ServerMarks(archived: [], completed: ["2"]) }, protected: { [] }, isCurrent: { true },
            assignments: cache.assignments
        )
        #expect(cache.assignments.loadArchivedAssignmentIds().isEmpty)
        #expect(cache.assignments.loadLocallyCompletedAssignmentIds() == ["2"])

        await AssignmentMarksReconciler.keepServerSide(
            read: { ServerMarks(archived: ["3"], completed: []) }, protected: { [] }, isCurrent: { false },
            assignments: cache.assignments
        )
        #expect(cache.assignments.loadLocallyCompletedAssignmentIds() == ["2"])
    }
}
