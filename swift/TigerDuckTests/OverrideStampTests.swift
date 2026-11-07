import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct OverrideStampTests {
    enum Edit: String, Sendable, CaseIterable { case colour, name, ignore, mark }

    enum Attempts: String, Sendable, CaseIterable {
        case lands, lostReplyThenLands

        func replies(_ body: Data) -> [(SettingsAPIStub.StubResponse, sentAge: Int64)] {
            let landed = SettingsAPIStub.StubResponse(statusCode: 200, body: body)
            switch self {
            case .lands: return [(landed, 1500)]
            case .lostReplyThenLands: return [(.noReply, 1500), (landed, 3500)]
            }
        }
    }

    private static let madeAt = Date(timeIntervalSince1970: 1_790_000_000.5)
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

    @Test("A queued edit goes with its age, measured again for each attempt", arguments: Edit.allCases, Attempts.allCases)
    func queuedEditCarriesItsAge(_ edit: Edit, _ attempts: Attempts) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(edit, baseURL)
        let replies = attempts.replies(edit == .mark ? Self.markReply : Self.courseReply)
        for (reply, _) in replies { SettingsAPIStub.enqueue(reply, for: url) }
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_002), step: 1)
        let coordinator = Self.makeCoordinator(baseURL, clock: { clock.now() })

        await coordinator.outbox.enqueue(Self.op(edit))
        await coordinator.syncTick()
        await coordinator.syncTick()

        let sent = SettingsAPIStub.requests(for: url)
        #expect(sent.count == replies.count)
        for (request, (_, sentAge)) in zip(sent, replies) {
            let json = try Self.json(request)
            #expect((json["age_ms"] as? NSNumber)?.int64Value == sentAge)
            #expect(json["hlc"] == nil)
            switch edit {
            case .colour: #expect(json["color_hex"] as? String == "#FF6B6B")
            case .name: #expect(json["custom_name"] as? String == "Algorithms")
            case .ignore: #expect(json["ignore_assignments"] as? Bool == true)
            case .mark: #expect(json["local_status"] as? String == "ignored")
            }
        }
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("An edit queued here carries its clock since boot through a relaunch, and one an earlier build queued without it goes aged by the wall clock")
    func queuedEditKeepsItsBootClock() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverrideStampTests-\(UUID().uuidString)", isDirectory: true)
        await SyncOutbox(directory: directory).enqueue(
            .assignmentOverride(moodleCourseId: 4242, moodleAssignmentId: 42, localStatus: "ignored", stamp: Date())
        )
        let reread = await SyncOutbox(directory: directory).snapshot().first?.madeAt
        #expect(reread?.sinceBoot != nil)
        #expect(reread?.boot != nil)

        let earlier = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverrideStampTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)
        try Data(Self.markQueuedByAnEarlierBuild.utf8).write(to: earlier.appendingPathComponent("outbox.json"))
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        let coordinator = Self.makeCoordinator(baseURL, outbox: SyncOutbox(directory: earlier))

        await coordinator.syncTick()

        let json = try Self.json(try #require(SettingsAPIStub.requests(for: url).first))
        #expect((json["age_ms"] as? NSNumber)?.int64Value == 1500)
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    private static let markQueuedByAnEarlierBuild = #"""
    [{"id":"6F9619FF-8B86-D011-B42D-00C04FC964F5","attempts":0,"op":{"assignmentOverride":{"moodleCourseId":4242,"moodleAssignmentId":42,"localStatus":"ignored","stamp":811692800.5}}}]
    """#

    @Test("An edit made after the earlier send of its field went out ages from that send's end; one made before it went out, or older, keeps its own age")
    func editMadeDuringAnEarlierSendAgesFromItsEnd() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        for _ in 0..<4 { SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url) }
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010), step: 1)
        let client = Self.client(baseURL, clock: { clock.now() })

        try await Self.mark(0, on: client)
        try await Self.mark(10.5, on: client)
        try await Self.mark(11.5, on: client)
        try await Self.mark(-1, on: client)

        #expect(try Self.sentAges(url) == [10_000, 1_000, 2_500, 17_000])
    }

    @Test("A retry of an edit that aged from an earlier send's end ages from it again")
    func retryKeepsTheTimeItAgedFrom() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        SettingsAPIStub.enqueue(.noReply, for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010), step: 1)
        let client = Self.client(baseURL, clock: { clock.now() })

        try await Self.mark(0, on: client)
        await #expect(throws: URLError.self) { try await Self.mark(10.5, on: client) }
        try await Self.mark(10.5, on: client)

        #expect(try Self.sentAges(url) == [10_000, 1_000, 3_000])
    }

    @Test("An edit of a field waits for the earlier send of that field to be answered, and ages from that answer")
    func editWaitsForTheEarlierSendOfItsField() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        let gate = SettingsAPIStub.ReplyGate()
        var held = SettingsAPIStub.StubResponse(statusCode: 200, body: Self.markReply)
        held.gate = gate
        SettingsAPIStub.enqueue(held, for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010))
        let client = Self.client(baseURL, clock: { clock.now() })

        let first = Task { try await Self.mark(0, on: client) }
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 1 }
        let second = Task { try await Self.mark(11, on: client) }
        clock.set(Date(timeIntervalSince1970: 1_790_000_012))
        gate.open()
        try await first.value
        try await second.value

        #expect(try Self.sentAges(url) == [10_000, 0])
    }

    @Test("An edit made while the earlier send of its field failed with no answer ages from that failure, as the backend may have taken it")
    func editAgesFromAnEarlierSendThatGotNoAnswer() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        SettingsAPIStub.enqueue(.noReply, for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010), step: 1)
        let client = Self.client(baseURL, clock: { clock.now() })

        await #expect(throws: URLError.self) { try await Self.mark(0, on: client) }
        try await Self.mark(10.5, on: client)

        #expect(try Self.sentAges(url) == [10_000, 1_000])
    }

    @Test("The answer to an older edit of a field does not replace the answer to a newer one")
    func olderEditsAnswerKeepsTheNewerOne() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        for _ in 0..<3 { SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url) }
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010), step: 1)
        let client = Self.client(baseURL, clock: { clock.now() })

        try await Self.mark(5, on: client)
        try await Self.mark(0, on: client)
        try await Self.mark(10.5, on: client)

        #expect(try Self.sentAges(url) == [5_000, 12_000, 3_000])
    }

    @Test("An answer to one sign-in's edit does not age the next sign-in's edit of that field")
    func answerDoesNotCarryToTheNextSignIn() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        for _ in 0..<2 { SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url) }
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010))
        let signIns = SignInSeries()
        let client = Self.client(baseURL, signIns: signIns, clock: { clock.now() })

        try await Self.mark(0, on: client, for: signIns.currentSignIn)
        signIns.end()
        clock.set(Date(timeIntervalSince1970: 1_790_000_012))
        try await Self.mark(5, on: client, for: signIns.currentSignIn)

        #expect(try Self.sentAges(url) == [10_000, 7_000])
    }

    @Test("A send measures its age once its token is in hand, which may wait on a refresh, and again when replayed with a refreshed one")
    func ageIsMeasuredOnceTheTokenIsInHand() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.url(.mark, baseURL)
        SettingsAPIStub.enqueue(.init(statusCode: 401, body: Data(#"{"error":"token_expired"}"#.utf8)), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.markReply), for: url)
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_002))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let refreshing = BackendAuth(header: {
            clock.set(clock.now().wall.addingTimeInterval(5))
            return ("Bearer test", testSignIn)
        }, recover: { _, _, _ in true })
        let client = PushAPIClient(
            baseURLProvider: { baseURL }, session: URLSession(configuration: config), auth: refreshing,
            editClock: { clock.now() }
        )

        try await Self.mark(0, on: client)

        #expect(try Self.sentAges(url) == [7_000, 12_000])
    }

    @Test("A term reset waits for a course delete still on its way, and ages from its answer")
    func resetWaitsForACourseDeleteOnItsWay() async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let delete = baseURL.appendingPathComponent("sync/courses/client:1151:CS1001301")
            .appending(queryItems: [URLQueryItem(name: "age_ms", value: "10000")])
        let reset = baseURL.appendingPathComponent("sync/courses").appending(queryItems: [
            URLQueryItem(name: "semester", value: "1151"), URLQueryItem(name: "age_ms", value: "0"),
        ])
        let gate = SettingsAPIStub.ReplyGate()
        var held = SettingsAPIStub.StubResponse(statusCode: 200, body: Data(#"{"applied":true,"hlc":1}"#.utf8))
        held.gate = gate
        SettingsAPIStub.enqueue(held, for: delete)
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Data(#"{"deleted":1,"applied":true,"reset_hlc":2}"#.utf8)), for: reset
        )
        let at = { (seconds: TimeInterval) in EditTime(wall: Date(timeIntervalSince1970: 1_790_000_000 + seconds)) }
        let clock = TestEditClock(Date(timeIntervalSince1970: 1_790_000_010))
        let client = Self.client(baseURL, clock: { clock.now() })

        let hide = Task { try await client.deleteCourse(courseKey: "client:1151:CS1001301", madeAt: at(0), for: testSignIn) }
        try await waitUntil { SettingsAPIStub.requests(under: baseURL).count == 1 }
        let resetting = Task { try await client.deleteAllCourses(semester: "1151", madeAt: at(11), for: testSignIn) }
        clock.set(Date(timeIntervalSince1970: 1_790_000_012))
        gate.open()
        try await hide.value

        #expect(try await resetting.value == 2)
        #expect(SettingsAPIStub.requests(under: baseURL).map(\.url?.query) == ["age_ms=10000", "semester=1151&age_ms=0"])
    }

    @Test("A holiday setting whose send failed goes again after a relaunch, aged from when it was made")
    func holidayRetryCarriesTheEditTime() async throws {
        let clock = TestEditClock(Date(), step: 1)
        try await Self.withCleanHolidayDefaults(clock: { clock.now() }) { id, url, registration in
            SettingsAPIStub.enqueue(.noReply, for: url)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(id)), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id, for: testSignIn)
            store.setHolidayAcknowledged(false, holidayID: id, for: testSignIn)
            let madeAt = try #require(store.holidayEdit(id).madeAt)
            #expect(madeAt.sinceBoot != nil)
            #expect(madeAt.boot != nil)
            clock.set(madeAt.wall.addingTimeInterval(5))

            await HolidaySettingSender.uploadHolidayOverride(id, from: store, via: registration, for: testSignIn)
            #expect(store.unacknowledgedHolidayIDs.contains(id))
            let relaunched = AcademicCalendarStore()
            #expect(relaunched.holidayEdit(id).madeAt == madeAt)
            await HolidaySettingSender.uploadHolidayOverride(id, from: relaunched, via: registration, for: testSignIn)

            let sent = SettingsAPIStub.requests(for: url)
            #expect(sent.count == 2)
            for request in sent {
                let json = try Self.json(request)
                #expect(json["notify"] as? Bool == true)
                #expect(json["hlc"] == nil)
            }
            #expect(try sent.map { try (Self.json($0)["age_ms"] as? NSNumber)?.int64Value } == [5000, 7000])
            #expect(!relaunched.unacknowledgedHolidayIDs.contains(id))
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

    private static func withCleanHolidayDefaults(
        clock: @escaping @Sendable () -> EditTime = { EditTime.testNow },
        _ body: (_ id: Int, _ url: URL, _ registration: PushRegistrationService) async throws -> Void
    ) async throws {
        try await withExclusiveRealDefaults {
            let saved = (
                Defaults[.holidayNotifyOverrides], Defaults[.holidayOverridesAwaitingUpload],
                Defaults[.holidayOverrideEditTimes], Defaults[.holidayOverrideEditClocks], Defaults[.cloudSyncEnabled]
            )
            defer {
                Defaults[.holidayNotifyOverrides, for: testSignIn] = saved.0
                Defaults[.holidayOverridesAwaitingUpload, for: testSignIn] = saved.1
                Defaults[.holidayOverrideEditTimes, for: testSignIn] = saved.2
                Defaults[.holidayOverrideEditClocks, for: testSignIn] = saved.3
                Defaults[.cloudSyncEnabled, for: testSignIn] = saved.4
            }
            Defaults[.cloudSyncEnabled, for: testSignIn] = true
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let id = Int.random(in: 100_000...999_999)
            try await body(
                id, baseURL.appendingPathComponent("sync/holiday-overrides/\(id)"),
                Self.pushCoordinator(baseURL, clock: clock).registration
            )
        }
    }

    private static func json(_ request: URLRequest) throws -> [String: Any] {
        let body = try #require(SettingsAPIStub.bodyData(from: request))
        return try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private static func url(_ edit: Edit, _ baseURL: URL) -> URL {
        baseURL.appendingPathComponent(
            edit == .mark ? "sync/assignments/42/override" : "sync/courses/client:1151:CS1001301/override"
        )
    }

    private static func client(
        _ baseURL: URL, signIns: SignInSeries = testSignIns, clock: @escaping @Sendable () -> EditTime
    ) -> PushAPIClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        return PushAPIClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" },
            signIns: signIns,
            editClock: clock
        )
    }

    private static func mark(
        _ seconds: TimeInterval, on client: PushAPIClient, for signIn: SignIn = testSignIn
    ) async throws {
        _ = try await client.patchAssignmentOverride(
            moodleAssignmentId: "42", localStatus: "ignored",
            madeAt: EditTime(wall: Date(timeIntervalSince1970: 1_790_000_000 + seconds)), for: signIn
        )
    }

    private static func sentAges(_ url: URL) throws -> [Int64?] {
        try SettingsAPIStub.requests(for: url).map { try (Self.json($0)["age_ms"] as? NSNumber)?.int64Value }
    }

    private static func pushCoordinator(
        _ baseURL: URL, clock: @escaping @Sendable () -> EditTime = { EditTime.testNow }
    ) -> PushCoordinator {
        PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client(baseURL, clock: clock))
    }

    private static func makeCoordinator(
        _ baseURL: URL, clock: @escaping @Sendable () -> EditTime = { EditTime.testNow },
        outbox: SyncOutbox = SyncOutbox(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("OverrideStampTests-\(UUID().uuidString)", isDirectory: true))
    ) -> CloudSyncCoordinator {
        CloudSyncCoordinator(
            pushCoordinator: pushCoordinator(baseURL, clock: clock), outbox: outbox, isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: { true }, syncsCourseOverrides: { _ in true },
            account: AccountSession(signIns: testSignIns)
        )
    }
}
