import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// The backend settles a colour, a name, an ignore setting, a mark and a holiday setting by the
/// time each was made, and stamps one sent without it when it arrives, so a late send would beat a
/// newer edit from another device. These check that every attempt carries the time of its edit.
@MainActor
struct OverrideStampTests {
    enum Edit: String, Sendable, CaseIterable { case colour, name, ignore, mark }

    enum Attempts: String, Sendable, CaseIterable {
        case lands, lostReplyThenLands, refusedAsAheadThenLandsUnstamped

        /// Each reply with whether the request it answers carries the edit's time.
        func replies(_ body: Data) -> [(SettingsAPIStub.StubResponse, stamped: Bool)] {
            let landed = SettingsAPIStub.StubResponse(statusCode: 200, body: body)
            switch self {
            case .lands: return [(landed, true)]
            case .lostReplyThenLands: return [(.noReply, true), (landed, true)]
            case .refusedAsAheadThenLandsUnstamped: return [(Self.clockAhead, true), (landed, false)]
            }
        }

        static let clockAhead = SettingsAPIStub.StubResponse(
            statusCode: 409, body: Data(#"{"detail":"clock_ahead"}"#.utf8)
        )
    }

    private static let madeAt = Date(timeIntervalSince1970: 1_790_000_000.5)
    private static let hlc: Int64 = 1_790_000_000_500_000
    private static let courseReply = Data(
        ##"{"id":1,"color_hex":"#FF6B6B","custom_names":{"zh":"Algorithms"},"ignore_assignments":true,"updated_at":"2026-10-13T00:00:00+00:00"}"##.utf8
    )

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
            edit == .mark ? "sync/assignments/42/override" : "sync/courses/1151CS1001301/override"
        )
        let replies = attempts.replies(edit == .mark ? Data("{}".utf8) : Self.courseReply)
        for (reply, _) in replies { SettingsAPIStub.enqueue(reply, for: url) }
        let coordinator = Self.makeCoordinator(baseURL)

        await coordinator.outbox.enqueue(Self.op(edit))
        await coordinator.syncTick()
        await coordinator.syncTick()

        let sent = SettingsAPIStub.requests(for: url)
        #expect(sent.count == replies.count)
        for (request, (_, stamped)) in zip(sent, replies) {
            let json = try Self.json(request)
            #expect((json["hlc"] as? NSNumber)?.int64Value == (stamped ? Self.hlc : nil))
            switch edit {
            case .colour: #expect(json["color_hex"] as? String == "#FF6B6B")
            case .name: #expect(json["custom_name"] as? String == "Algorithms")
            case .ignore: #expect(json["ignore_assignments"] as? Bool == true)
            case .mark: #expect(json["local_status"] as? String == "ignored")
            }
        }
        #expect(await coordinator.outbox.pendingCount() == 0)
    }

    @Test("A holiday setting whose send failed goes again after a relaunch with the time it was made")
    func holidayRetryCarriesTheEditTime() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            SettingsAPIStub.enqueue(.noReply, for: url)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id)
            store.setHolidayAcknowledged(false, holidayID: id)
            let madeAt = try #require(store.holidayEdit(id).madeAt)

            await AppState.uploadHolidayOverride(id, from: store, via: registration)
            #expect(store.unacknowledgedHolidayIDs.contains(id))
            let retriedAt = Date()
            let relaunched = AcademicCalendarStore()
            await AppState.uploadHolidayOverride(id, from: relaunched, via: registration)

            let sent = SettingsAPIStub.requests(for: url)
            #expect(sent.count == 2)
            for request in sent {
                let json = try Self.json(request)
                #expect(json["notify"] as? Bool == true)
                #expect((json["hlc"] as? NSNumber)?.int64Value == PushAPI.clock(of: madeAt))
            }
            #expect(PushAPI.clock(of: madeAt) < PushAPI.clock(of: retriedAt))
            #expect(!relaunched.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting refused as ahead of the server's clock goes again without its time")
    func holidayAheadOfTheServerGoesUnstamped() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            SettingsAPIStub.enqueue(Attempts.clockAhead, for: url)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8)), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id)
            store.setHolidayAcknowledged(false, holidayID: id)

            await AppState.uploadHolidayOverride(id, from: store, via: registration)

            let stamps = try SettingsAPIStub.requests(for: url).map { try (Self.json($0)["hlc"] as? NSNumber)?.int64Value }
            let madeAt = try #require(store.holidayEdit(id).madeAt)
            #expect(stamps == [PushAPI.clock(of: madeAt), nil])
            #expect(!store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting changed and changed back while its send is out stays unacknowledged for the newer time")
    func holidayEditDuringTheSendKeepsItUnacknowledged() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            let gate = SettingsAPIStub.ReplyGate()
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Data("{}".utf8), gate: gate), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id)
            store.setHolidayAcknowledged(false, holidayID: id)

            let upload = Task { await AppState.uploadHolidayOverride(id, from: store, via: registration) }
            try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
            store.setNotify(false, forHoliday: id)
            store.setNotify(true, forHoliday: id)
            gate.open()
            await upload.value

            #expect(store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    private static func withCleanHolidayDefaults(
        _ body: (_ id: Int, _ url: URL, _ registration: PushRegistrationService) async throws -> Void
    ) async throws {
        try await withExclusiveRealDefaults {
            let saved = (
                Defaults[.holidayNotifyOverrides], Defaults[.holidayOverridesAwaitingUpload],
                Defaults[.holidayOverrideEditTimes]
            )
            defer {
                Defaults[.holidayNotifyOverrides] = saved.0
                Defaults[.holidayOverridesAwaitingUpload] = saved.1
                Defaults[.holidayOverrideEditTimes] = saved.2
            }
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

    private static func pushCoordinator(_ baseURL: URL) -> PushCoordinator {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = PushAPIClient(
            baseURLProvider: { baseURL },
            session: URLSession(configuration: config),
            authHeaderProvider: { "Bearer test" }
        )
        return PushCoordinator(identity: PushIdentity(uuid: "test-device"), apiClient: client)
    }

    private static func makeCoordinator(_ baseURL: URL) -> CloudSyncCoordinator {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OverrideStampTests-\(UUID().uuidString)", isDirectory: true)
        return CloudSyncCoordinator(
            pushCoordinator: pushCoordinator(baseURL), outbox: SyncOutbox(directory: directory), isEnabled: true,
            syncsAssignmentMarks: { true }, syncsCourseIgnores: { true }, syncsCourseOverrides: { _ in true }
        )
    }
}
