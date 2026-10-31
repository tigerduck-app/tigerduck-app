import Foundation
import Testing
@testable import TigerDuck

/// The backend settles a colour, a name, an ignore setting and a mark by the time each was made,
/// and stamps one sent without it when it arrives, so a late send would beat a newer edit from
/// another device. These check that every attempt carries the time of its edit.
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
