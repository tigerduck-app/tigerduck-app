import Defaults
import Foundation
import os
import Testing
@testable import TigerDuck

@MainActor
struct OverrideStampTests {
    enum Edit: String, Sendable, CaseIterable { case colour, name, ignore, mark }

    enum Attempts: String, Sendable, CaseIterable {
        case lands, lostReplyThenLands, refusedAsAheadThenLandsRestamped

        func replies(_ body: Data) -> [(SettingsAPIStub.StubResponse, sentStamp: Int64)] {
            let landed = SettingsAPIStub.StubResponse(statusCode: 200, body: body)
            switch self {
            case .lands: return [(landed, OverrideStampTests.hlc)]
            case .lostReplyThenLands: return [(.noReply, OverrideStampTests.hlc), (landed, OverrideStampTests.hlc)]
            case .refusedAsAheadThenLandsRestamped:
                return [(Self.clockAhead, OverrideStampTests.hlc), (landed, Self.serverClock + 1)]
            }
        }

        static let serverClock: Int64 = 1_789_999_000_000_000
        static let clockAhead = SettingsAPIStub.StubResponse(
            statusCode: 409, body: Data(#"{"error":"clock_ahead","message":"ahead"}"#.utf8),
            headerFields: ["X-TigerSync-Clock": String(serverClock)]
        )
    }

    private static let madeAt = Date(timeIntervalSince1970: 1_790_000_000.5)
    fileprivate static let hlc: Int64 = 1_790_000_000_500_000
    private static let courseReply = Data(
        ##"{"color_hex":"#FF6B6B","custom_names":{"zh":"Algorithms"},"ignore_assignments":true,"applied":["color_hex","custom_name","ignore_assignments"]}"##.utf8
    )
    private static let markReply = Data(#"{"local_status":"ignored","local_status_hlc":1,"applied":true}"#.utf8)

    private static func holidayReply(_ id: Int) -> Data {
        Data(#"{"holiday_id":\#(id),"notify":true,"hlc":1,"applied":true}"#.utf8)
    }

    private static func op(_ edit: Edit) -> SyncOp {
        switch edit {
        case .colour:
            return .courseOverride(semester: "1151", moodleId: "1151CS1001301", customName: nil,
                                   colorHex: "#FF6B6B", locale: nil, stamp: madeAt)
        case .name:
            return .courseOverride(semester: "1151", moodleId: "1151CS1001301", customName: "Algorithms",
                                   colorHex: nil, locale: "zh", stamp: madeAt)
        case .ignore:
            return .courseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                 moodleCourseId: 4242, ignore: true, stamp: madeAt)
        case .mark:
            return .assignmentOverride(moodleCourseId: 4242, moodleAssignmentId: 42, localStatus: "ignored", stamp: madeAt)
        }
    }

    @Test("A queued edit is sent with the time it was made, not the time it is sent", arguments: Edit.allCases, Attempts.allCases)
    func queuedEditCarriesItsOwnTime(_ edit: Edit, _ attempts: Attempts) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent(
            edit == .mark ? "sync/assignments/42/override" : "sync/courses/client:1151:CS1001301/override"
        )
        let replies = attempts.replies(edit == .mark ? Self.markReply : Self.courseReply)
        for (reply, _) in replies { SettingsAPIStub.enqueue(reply, for: url) }
        let coordinator = Self.makeCoordinator(baseURL)

        await coordinator.outbox.enqueue(Self.op(edit))
        await coordinator.syncTick()
        await coordinator.syncTick()

        let sent = SettingsAPIStub.requests(for: url)
        #expect(sent.count == replies.count)
        for (request, (_, sentStamp)) in zip(sent, replies) {
            let json = try Self.json(request)
            #expect((json["hlc"] as? NSNumber)?.int64Value == sentStamp)
            switch edit {
            case .colour: #expect(json["color_hex"] as? String == "#FF6B6B")
            case .name: #expect(json["custom_name"] as? String == "Algorithms")
            case .ignore: #expect(json["ignore_assignments"] as? Bool == true)
            case .mark: #expect(json["local_status"] as? String == "ignored")
            }
        }
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("A clock_ahead resend waits for a hold that started during the first send", arguments: Edit.allCases)
    func aheadResendWaitsForAHoldStartedDuringTheSend(_ edit: Edit) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent(
            edit == .mark ? "sync/assignments/42/override" : "sync/courses/client:1151:CS1001301/override"
        )
        let gate = SettingsAPIStub.ReplyGate()
        var refused = Attempts.clockAhead
        refused.gate = gate
        SettingsAPIStub.enqueue(refused, for: url)
        let conflictCheckOwed = OSAllocatedUnfairLock(initialState: false)
        let coordinator = Self.makeCoordinator(baseURL, conflictCheckOwed: { conflictCheckOwed.withLock { $0 } })
        await coordinator.outbox.enqueue(Self.op(edit))

        let tick = Task { await coordinator.syncTick() }
        try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
        conflictCheckOwed.withLock { $0 = true }
        gate.open()
        await tick.value

        #expect(SettingsAPIStub.requests(for: url).count == 1)
        #expect(await coordinator.outbox.snapshot().map(\.attempts) == [0])
    }

    @Test("A holiday setting whose send failed goes again after a relaunch with the time it was made")
    func holidayRetryCarriesTheEditTime() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            SettingsAPIStub.enqueue(.noReply, for: url)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(id)), for: url)
            let device = SyncClockTests.DeviceClock(Self.deviceTime)
            let clock = SyncClockTests.makeClock(device)
            let store = AcademicCalendarStore(clock: clock)
            store.setNotify(true, forHoliday: id, for: testSignIn)
            store.setHolidayAcknowledged(false, holidayID: id, for: testSignIn)
            let madeAt = try #require(store.holidayEdit(id).madeAt)

            await HolidaySettingSender.uploadHolidayOverride(id, from: store, via: registration, for: testSignIn)
            #expect(store.unacknowledgedHolidayIDs.contains(id))
            device.set(Self.deviceTime + 60 * SyncClockTests.minute)
            let relaunched = AcademicCalendarStore(clock: clock)
            await HolidaySettingSender.uploadHolidayOverride(id, from: relaunched, via: registration, for: testSignIn)

            let sent = SettingsAPIStub.requests(for: url)
            #expect(sent.count == 2)
            for request in sent {
                let json = try Self.json(request)
                #expect(json["notify"] as? Bool == true)
                #expect((json["hlc"] as? NSNumber)?.int64Value == Self.deviceTime + 1)
            }
            #expect(PushAPI.clock(of: madeAt) == Self.deviceTime + 1)
            #expect(!relaunched.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting refused as ahead of the server's clock goes again stamped one tick after that clock")
    func holidayAheadOfTheServerGoesRestamped() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            SettingsAPIStub.enqueue(Attempts.clockAhead, for: url)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(id)), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id, for: testSignIn)
            store.setHolidayAcknowledged(false, holidayID: id, for: testSignIn)

            await HolidaySettingSender.uploadHolidayOverride(id, from: store, via: registration, for: testSignIn)

            let stamps = try SettingsAPIStub.requests(for: url).map { try (Self.json($0)["hlc"] as? NSNumber)?.int64Value }
            let madeAt = try #require(store.holidayEdit(id).madeAt)
            #expect(stamps == [PushAPI.clock(of: madeAt), Attempts.serverClock + 1])
            #expect(!store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting refused as ahead waits when cloud sync turns off during its first send")
    func holidayAheadResendWaitsWhenSyncTurnsOff() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            let gate = SettingsAPIStub.ReplyGate()
            var refused = Attempts.clockAhead
            refused.gate = gate
            SettingsAPIStub.enqueue(refused, for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id, for: testSignIn)
            store.setHolidayAcknowledged(false, holidayID: id, for: testSignIn)

            let upload = Task { await HolidaySettingSender.uploadHolidayOverride(id, from: store, via: registration, for: testSignIn) }
            try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
            Defaults[.cloudSyncEnabled, for: testSignIn] = false
            gate.open()
            await upload.value

            #expect(SettingsAPIStub.requests(for: url).count == 1)
            #expect(store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting changed and changed back while its send is out stays unacknowledged for the newer time")
    func holidayEditDuringTheSendKeepsItUnacknowledged() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            let gate = SettingsAPIStub.ReplyGate()
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(id), gate: gate), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id, for: testSignIn)
            store.setHolidayAcknowledged(false, holidayID: id, for: testSignIn)

            let upload = Task { await HolidaySettingSender.uploadHolidayOverride(id, from: store, via: registration, for: testSignIn) }
            try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
            store.setNotify(false, forHoliday: id, for: testSignIn)
            store.setNotify(true, forHoliday: id, for: testSignIn)
            gate.open()
            await upload.value

            #expect(store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    private static let deviceTime = SyncClockTests.ten

    @Test("An edit made here is queued with the clock's stamp and sent with it as hlc", arguments: Edit.allCases)
    func editIsSentWithTheClocksStamp(_ edit: Edit) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent(
            edit == .mark ? "sync/assignments/42/override" : "sync/courses/client:1151:CS1001301/override"
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: edit == .mark ? Self.markReply : Self.courseReply), for: url)
        let clock = SyncClockTests.makeClock(SyncClockTests.DeviceClock(Self.deviceTime))
        let coordinator = Self.makeCoordinator(baseURL, clock: clock)

        switch edit {
        case .colour:
            await coordinator.enqueueCourseColorOverride(moodleId: "1151CS1001301", semester: "1151", colorHex: "#FF6B6B")?.value
        case .name:
            await coordinator.enqueueCourseNameOverride(
                moodleId: "1151CS1001301", semester: "1151", customName: "Algorithms", locale: "zh"
            )?.value
        case .ignore:
            await coordinator.enqueueCourseIgnore(
                semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301", moodleCourseId: 4242, ignore: true
            )
        case .mark:
            await coordinator.enqueueAssignmentOverride(moodleCourseId: 4242, moodleAssignmentId: 42, localStatus: "ignored")
        }
        await coordinator.syncTick()

        let sent = try #require(SettingsAPIStub.requests(for: url).first)
        #expect((try Self.json(sent)["hlc"] as? NSNumber)?.int64Value == Self.deviceTime + 1)
        #expect(clock.readings.lastIssued == Self.deviceTime + 1)
    }

    @Test("An entry the previous release queued goes stamped with the time it was queued")
    func entryFromThePreviousReleaseKeepsItsQueueTime() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = baseURL.appendingPathComponent("sync/assignments/42/override")
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        let directory = Self.outboxDirectory()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(#"""
        [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964F5","attempts":0,"op":{"assignmentOverride":{"moodleCourseId":4242,"moodleAssignmentId":42,"localStatus":"ignored","stamp":811692800.25}}}]
        """#.utf8).write(to: directory.appendingPathComponent(OutboxFiles.fileName))
        let clock = SyncClockTests.makeClock(SyncClockTests.DeviceClock(Self.deviceTime + SyncClockTests.minute))
        let coordinator = Self.makeCoordinator(baseURL, clock: clock, outboxIn: directory)

        await coordinator.syncTick()

        let sent = try #require(SettingsAPIStub.requests(for: url).first)
        #expect((try Self.json(sent)["hlc"] as? NSNumber)?.int64Value == 1_790_000_000_250_000)
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("Use Server drops a colour queued just before it on a device whose clock is behind the backend")
    func useServerDropsAnEditStampedAheadOfTheDevice() async {
        let now = PushAPI.clock(of: Date())
        let clock = SyncClockTests.makeClock(SyncClockTests.DeviceClock(now))
        await clock.hear(now + 10 * SyncClockTests.minute)
        let coordinator = Self.makeCoordinator(SettingsAPIStub.uniqueBaseURL(), clock: clock)

        await coordinator.enqueueCourseColorOverride(moodleId: "1151CS1001301", semester: "1151", colorHex: "#FF6B6B")?.value
        await coordinator.discardEdits(of: [.courseColors], courseIgnores: false)

        #expect(await coordinator.pendingCourseOverrides().colors.isEmpty)
    }

    @Test("A colour picked after Use Server on a device whose clock is ahead of the backend stays queued")
    func editAfterUseServerOnADeviceAheadStays() async {
        let now = PushAPI.clock(of: Date())
        let clock = SyncClockTests.makeClock(SyncClockTests.DeviceClock(now))
        await clock.hear(now - 60 * SyncClockTests.minute)
        let coordinator = Self.makeCoordinator(SettingsAPIStub.uniqueBaseURL(), clock: clock)

        await coordinator.discardEdits(of: [.courseColors], courseIgnores: false)
        await coordinator.enqueueCourseColorOverride(moodleId: "1151CS1001301", semester: "1151", colorHex: "#FF6B6B")?.value

        #expect(await coordinator.pendingCourseOverrides().colors == ["1151CS1001301"])
    }

    private static func withCleanHolidayDefaults(
        _ body: (_ id: Int, _ url: URL, _ registration: PushRegistrationService) async throws -> Void
    ) async throws {
        try await withExclusiveRealDefaults {
            let saved = (
                Defaults[.holidayNotifyOverrides], Defaults[.holidayOverridesAwaitingUpload],
                Defaults[.holidayOverrideEditTimes], Defaults[.cloudSyncEnabled]
            )
            defer {
                Defaults[.holidayNotifyOverrides, for: testSignIn] = saved.0
                Defaults[.holidayOverridesAwaitingUpload, for: testSignIn] = saved.1
                Defaults[.holidayOverrideEditTimes, for: testSignIn] = saved.2
                Defaults[.cloudSyncEnabled, for: testSignIn] = saved.3
            }
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let id = Int.random(in: 100_000...999_999)
            try await body(
                id, baseURL.appendingPathComponent("sync/holiday-overrides/\(id)"),
                Self.pushCoordinator(baseURL).registration
            )
        }
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func pushCoordinator(_ baseURL: URL, clock: SyncClock? = nil) -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" },
            clock: clock
        )
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
    }

    private nonisolated static func outboxDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("OverrideStampTests-\(UUID().uuidString)", isDirectory: true)
    }

    private static func makeCoordinator(
        _ baseURL: URL, conflictCheckOwed: @escaping @Sendable () -> Bool = { false },
        clock: SyncClock? = nil, outboxIn directory: URL = outboxDirectory()
    ) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            pushCoordinator: pushCoordinator(baseURL, clock: clock), outbox: SyncOutbox(directory: directory), isEnabled: true,
            syncsAssignmentMarks: { !conflictCheckOwed() }, syncsCourseIgnores: { !conflictCheckOwed() }, syncsCourseOverrides: { _ in !conflictCheckOwed() },
            account: AccountSession(signIns: testSignIns), clock: clock ?? .shared
        )
    }
}
