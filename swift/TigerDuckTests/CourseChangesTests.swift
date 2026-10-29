import Defaults
import Foundation
import Testing
@testable import TigerDuck

// Serialized because the feed and store tests write the stored feed that every slot build reads.
@MainActor
@Suite("Course changes", .serialized)
struct CourseChangesTests {
    private static let thursday = AppConstants.taipeiCalendar.date(
        from: DateComponents(year: 2026, month: 11, day: 5, hour: 7)
    )!

    private static func at(_ time: String, on day: Date = CourseChangesTests.thursday) -> Date {
        CourseTimeSlot.dateFromTimeString(time, on: day)!
    }

    private static func row(
        _ id: Int, _ kind: String, periods: [String]? = nil, days: [String] = ["2026-11-05"],
        values: [String: String] = [:]
    ) -> [String: Any] {
        var row: [String: Any] = [
            "id": id, "course_no": "CC900", "kind": kind, "mode": "day", "day": days[0],
            "from": NSNull(), "to": NSNull(), "excluded_weekdays": [Int](), "periods": periods.map { $0 as Any } ?? NSNull(),
            "class_days": days, "room": NSNull(), "start": NSNull(), "end": NSNull(),
            "note_zh": NSNull(), "note_en": NSNull(), "updated_at": "2026-10-29T14:03:00+08:00",
        ]
        for (key, value) in values { row[key] = value }
        return row
    }

    private static func feed(_ rows: [[String: Any]]) -> Data {
        try! JSONSerialization.data(withJSONObject: ["term": "1151", "changes": rows] as [String: Any])
    }

    private static func changes(_ rows: [[String: Any]]) throws -> CourseChanges {
        try CourseChanges(json: feed(rows))
    }

    @Test func decodesTheFeedAndDropsUnknownKindsAndIncompleteRows() throws {
        let changes = try Self.changes([
            Self.row(42, "cancelled"),
            Self.row(43, "moved_online", values: ["room": "Teams"]),
            Self.row(44, "room"),
            Self.row(45, "note", values: ["note_zh": "期中考"]),
            Self.row(46, "room", days: ["2026-11-12"], values: ["room": "TR-313"]),
        ])

        let thatDay = changes.changes(courseNo: "CC900", on: Self.thursday)
        #expect(changes.term == "1151")
        #expect(thatDay.map(\.id) == [42, 45])
        #expect(thatDay.last?.noteEn == "期中考")
        #expect(changes.changes(courseNo: "CC900", on: Self.at("23:59")).map(\.id) == [42, 45])
        #expect(changes.changes(courseNo: "CC901", on: Self.thursday).isEmpty)
    }

    @Test func theStoreSendsItsETagKeepsItsCopyOnA304AndReplacesItOnA200() async throws {
        let savedCache = Defaults[.courseChangesCache]
        let savedTag = Defaults[.courseChangesETag]
        defer {
            Defaults[.courseChangesCache] = savedCache
            Defaults[.courseChangesETag] = savedTag
        }
        Defaults[.courseChangesCache] = Data()
        Defaults[.courseChangesETag] = ""
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appendingPathComponent("calendar").appendingPathComponent("course-changes")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let store = CourseChangeStore(session: URLSession(configuration: config), baseURL: { base })
        let first = Self.feed([Self.row(1, "cancelled")])

        SettingsAPIStub.enqueue(.init(statusCode: 200, body: first, headerFields: ["ETag": #"W/"a""#]), for: url)
        #expect(await store.refresh())
        #expect(CourseChanges.cached.changes(courseNo: "CC900", on: Self.thursday).map(\.id) == [1])

        SettingsAPIStub.enqueue(.init(statusCode: 304, body: Data()), for: url)
        #expect(await store.refresh() == false)
        SettingsAPIStub.enqueue(.init(statusCode: 404, body: Data()), for: url)
        #expect(await store.refresh() == false)
        #expect(Defaults[.courseChangesCache] == first)

        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.feed([]), headerFields: ["ETag": #"W/"b""#]), for: url)
        #expect(await store.refresh())
        #expect(CourseChanges.cached.changes(courseNo: "CC900", on: Self.thursday).isEmpty)
        #expect(Defaults[.courseChangesETag] == #"W/"b""#)

        let sent = SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "If-None-Match") }
        #expect(sent == [nil, #"W/"a""#, #"W/"a""#, #"W/"a""#])
    }
}
