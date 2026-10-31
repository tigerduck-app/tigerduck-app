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

    private static func op(_ edit: Edit, value: String? = nil, at stamp: Date = madeAt) -> SyncOp {
        let value = value ?? Self.value(edit, .sent)
        switch edit {
        case .colour:
            return .courseOverride(semester: "1151", moodleId: "1151CS1001301", customName: nil,
                                   colorHex: value, locale: nil, stamp: stamp)
        case .name:
            return .courseOverride(semester: "1151", moodleId: "1151CS1001301", customName: value,
                                   colorHex: nil, locale: "zh", stamp: stamp)
        case .ignore:
            return .courseIgnore(semester: "1151", courseNo: "CS1001301", moodleId: "1151CS1001301",
                                 moodleCourseId: 4242, ignore: value == "true", stamp: stamp)
        case .mark:
            return .assignmentOverride(moodleCourseId: 4242, moodleAssignmentId: 42, localStatus: value, stamp: stamp)
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

    enum Settled: String, Sendable, CaseIterable { case applied, keptNewer, beforeStamps }

    /// The value each edit sends, the one the server's reply keeps instead, and one made here after
    /// the send. An ignore setting has two values, so its newer edit sets the sent one again.
    private static func value(_ edit: Edit, _ which: Value) -> String {
        switch (edit, which) {
        case (.colour, .sent): "#FF6B6B"
        case (.colour, .server): "#00AAFF"
        case (.colour, .newer): "#123456"
        case (.name, .sent): "Algorithms"
        case (.name, .server): "Other"
        case (.name, .newer): "Newer"
        case (.ignore, .sent), (.ignore, .newer): "true"
        case (.ignore, .server): "false"
        case (.mark, .sent): "ignored"
        case (.mark, .server): "locally_completed"
        case (.mark, .newer): "none"
        }
    }

    enum Value { case sent, server, newer }

    /// This device's stores with the edit's course, holding `value`.
    @MainActor
    private struct Local {
        let cache: DataCache
        let colors: ColorState

        init(_ edit: Edit, holding value: String) {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("OverrideStampTests-\(UUID().uuidString)", isDirectory: true)
            cache = DataCache(
                cacheDir: root.appendingPathComponent("cache", isDirectory: true),
                persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
            )
            cache.saveCourses(
                [SDCourse(courseNo: "CS1001301", courseName: "Programming", moodleIdNumber: "1151CS1001301", semester: "1151")],
                semester: "1151"
            )
            let box = ColorBox()
            colors = ColorState(
                load: { box.map }, save: { box.map = $0 }, notePick: { _ in }, forgetPicks: {},
                protectedDataAvailable: { true }
            )
            set(edit, to: value)
        }

        func set(_ edit: Edit, to value: String) {
            switch edit {
            case .colour:
                _ = colors.applyColors([("CS1001301", UInt32(value.dropFirst(), radix: 16)!)], palette: TigerDuckTheme.coursePaletteHexes)
            case .name: cache.saveCourseCustomNames(["CS1001301": ["zh": value]])
            case .ignore: cache.replaceIgnoredAssignmentCourses(value == "true" ? ["1151:CS1001301"] : [])
            case .mark:
                cache.replaceArchivedAssignmentIds(value == "ignored" ? ["42"] : [])
                cache.replaceLocallyCompletedAssignmentIds(value == "locally_completed" ? ["42"] : [])
            }
        }

        func value(_ edit: Edit) -> String? {
            switch edit {
            case .colour: colors.snapshot()["CS1001301"].map { String(format: "#%06X", $0) }
            case .name: cache.loadCourseCustomNames()["CS1001301"]?["zh"]
            case .ignore: String(cache.loadIgnoredAssignmentCourses().contains("1151:CS1001301"))
            case .mark:
                cache.loadArchivedAssignmentIds().contains("42") ? "ignored"
                    : cache.loadLocallyCompletedAssignmentIds().contains("42") ? "locally_completed" : "none"
            }
        }

        func takesKeptValues(from coordinator: CloudSyncCoordinator) {
            coordinator.adoptKeptValue = { [cache, colors] kept in
                _ = AppState.adopt(kept, into: cache) { colors.applyColors($0, palette: TigerDuckTheme.coursePaletteHexes) }
            }
        }
    }

    private nonisolated final class ColorBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String: UInt32] = [:]
        var map: [String: UInt32] {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// A reply that names the edit applied, one that names it kept out for the server's newer value,
    /// and one from a backend before TigerSync stamps, which names neither.
    private static func reply(_ edit: Edit, _ settled: Settled) -> Data {
        let applied: String
        switch (edit, settled) {
        case (_, .beforeStamps): applied = ""
        case (.mark, .applied): applied = #","applied":true"#
        case (.mark, .keptNewer): applied = #","applied":false"#
        case (_, .keptNewer): applied = #","applied":[]"#
        case (.colour, .applied): applied = #","applied":["color_hex"]"#
        case (.name, .applied): applied = #","applied":["custom_name"]"#
        case (.ignore, .applied): applied = #","applied":["ignore_assignments"]"#
        }
        let reply = edit == .mark
            ? #"{"id":1,"local_status":"locally_completed","local_status_hlc":1790000000500000,"updated_at":"2026-10-13T00:00:00+00:00""#
            : ##"{"id":1,"color_hex":"#00AAFF","custom_names":{"zh":"Other"},"ignore_assignments":false,"updated_at":"2026-10-13T00:00:00+00:00""##
        return Data((reply + applied + "}").utf8)
    }

    private static func overrideURL(_ edit: Edit, under baseURL: URL) -> URL {
        baseURL.appendingPathComponent(edit == .mark ? "sync/assignments/42/override" : "sync/courses/1151CS1001301/override")
    }

    @Test("An edit the server keeps out for a newer value leaves the server's value stored here", arguments: Edit.allCases, Settled.allCases)
    func editKeptOutForANewerValueTakesIt(_ edit: Edit, _ settled: Settled) async {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.reply(edit, settled)), for: Self.overrideURL(edit, under: baseURL))
        let coordinator = Self.makeCoordinator(baseURL)
        let local = Local(edit, holding: Self.value(edit, .sent))
        local.takesKeptValues(from: coordinator)

        await coordinator.outbox.enqueue(Self.op(edit))
        await coordinator.syncTick()

        #expect(await coordinator.outbox.pendingCount() == 0)
        #expect(local.value(edit) == Self.value(edit, settled == .keptNewer ? .server : .sent))
    }

    @Test("An edit made here while the one before it was out keeps its value when the server keeps out the one before", arguments: Edit.allCases)
    func newerEditQueuedDuringTheSendIsKept(_ edit: Edit) async throws {
        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = Self.overrideURL(edit, under: baseURL)
        let gate = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.reply(edit, .keptNewer), gate: gate), for: url)
        let coordinator = Self.makeCoordinator(baseURL)
        let local = Local(edit, holding: Self.value(edit, .sent))
        local.takesKeptValues(from: coordinator)
        await coordinator.outbox.enqueue(Self.op(edit))

        let drain = Task { await coordinator.syncTick() }
        try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
        local.set(edit, to: Self.value(edit, .newer))
        await coordinator.outbox.enqueue(Self.op(edit, value: Self.value(edit, .newer), at: Self.madeAt.addingTimeInterval(60)))
        gate.open()
        await drain.value

        #expect(local.value(edit) == Self.value(edit, .newer))
        #expect(await coordinator.outbox.pendingCount() == 1)
    }

    @Test("A holiday setting the server keeps out for a newer one takes that setting with the server's time", arguments: Settled.allCases)
    func holidayKeptOutForANewerSettingTakesIt(_ settled: Settled) async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(id, settled)), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id)
            store.setHolidayAcknowledged(false, holidayID: id)
            let madeHere = store.holidayEdit(id).madeAt

            let took = await AppState.uploadHolidayOverride(id, from: store, via: registration)

            #expect(took == (settled == .keptNewer))
            #expect(store.holidayEdit(id).notify == (settled != .keptNewer))
            #expect(store.holidayEdit(id).madeAt == (settled == .keptNewer ? PushAPI.date(ofClock: Self.hlc) : madeHere))
            #expect(!store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting kept out while another holiday's upload is still out takes the server's setting")
    func holidayKeptOutWhileAnotherUploadsTakesIt() async throws {
        try await Self.withCleanHolidayDefaults { kept, keptURL, registration in
            let other = kept + 1
            let otherURL = keptURL.deletingLastPathComponent().appendingPathComponent(String(other))
            let gate = SettingsAPIStub.ReplyGate()
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(other, .applied), gate: gate), for: otherURL)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(kept, .keptNewer)), for: keptURL)
            let store = AcademicCalendarStore()
            for id in [kept, other] {
                store.setNotify(true, forHoliday: id)
                store.setHolidayAcknowledged(false, holidayID: id)
            }

            let otherUpload = Task { await AppState.uploadHolidayOverride(other, from: store, via: registration) }
            try await waitUntil { !SettingsAPIStub.requests(for: otherURL).isEmpty }
            #expect(await AppState.uploadHolidayOverride(kept, from: store, via: registration))
            #expect(store.holidayEdit(kept).notify == false)
            gate.open()
            #expect(await otherUpload.value == false)

            #expect(store.holidayEdit(kept).notify == false)
            #expect(store.holidayEdit(other).notify == true)
            #expect(store.unacknowledgedHolidayIDs.isDisjoint(with: [kept, other]))
        }
    }

    private static func holidayReply(_ id: Int, _ settled: Settled) -> Data {
        let applied = [Settled.applied: #","applied":true"#, .keptNewer: #","applied":false"#][settled] ?? ""
        let notify = settled == .keptNewer ? "false" : "true"
        return Data((#"{"holiday_id":\#(id),"notify":\#(notify),"hlc":\#(hlc)"# + applied + "}").utf8)
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

            #expect(await AppState.uploadHolidayOverride(id, from: store, via: registration) == false)
            #expect(store.unacknowledgedHolidayIDs.contains(id))
            let retriedAt = Date()
            let relaunched = AcademicCalendarStore()
            #expect(await AppState.uploadHolidayOverride(id, from: relaunched, via: registration) == false)

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

            #expect(await AppState.uploadHolidayOverride(id, from: store, via: registration) == false)

            let stamps = try SettingsAPIStub.requests(for: url).map { try (Self.json($0)["hlc"] as? NSNumber)?.int64Value }
            let madeAt = try #require(store.holidayEdit(id).madeAt)
            #expect(stamps == [PushAPI.clock(of: madeAt), nil])
            #expect(!store.unacknowledgedHolidayIDs.contains(id))
        }
    }

    @Test("A holiday setting changed and changed back while its send is out keeps its value and stays unacknowledged for the newer time")
    func holidayEditDuringTheSendKeepsItUnacknowledged() async throws {
        try await Self.withCleanHolidayDefaults { id, url, registration in
            let gate = SettingsAPIStub.ReplyGate()
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.holidayReply(id, .keptNewer), gate: gate), for: url)
            let store = AcademicCalendarStore()
            store.setNotify(true, forHoliday: id)
            store.setHolidayAcknowledged(false, holidayID: id)

            let upload = Task { await AppState.uploadHolidayOverride(id, from: store, via: registration) }
            try await waitUntil { !SettingsAPIStub.requests(for: url).isEmpty }
            store.setNotify(false, forHoliday: id)
            store.setNotify(true, forHoliday: id)
            gate.open()

            #expect(await upload.value == false)
            #expect(store.holidayEdit(id).notify == true)
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
