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

    /// Meets Thursday in two meetings, periods 2 to 4 and 7 to 8.
    private static func course() -> SDCourse {
        SDCourse(courseNo: "CC900", courseName: "Compilers", classroom: "T4-501", schedule: [4: ["2", "3", "4", "7", "8"]])
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

    private static func slots(_ changes: CourseChanges, on day: Date = CourseChangesTests.thursday) -> [CourseTimeSlot] {
        CourseTimeSlot.buildSlots(from: [course()], weekday: 4, on: day, changes: changes)
    }

    private static func withStoredFeed<T>(_ data: Data, _ body: () throws -> T) rethrows -> T {
        let saved = Defaults[.courseChangesCache]
        defer { Defaults[.courseChangesCache] = saved }
        Defaults[.courseChangesCache] = data
        return try body()
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
        #expect(Self.slots(changes).map(\.id) == ["CC900_20261105_2", "CC900_20261105_7"])
    }

    @Test func aCancellationWithoutPeriodsCancelsEveryMeetingThatDayOnly() throws {
        let changes = try Self.changes([Self.row(1, "cancelled")])

        #expect(Self.slots(changes).map(\.isCancelled) == [true, true])
        let nextWeek = Self.thursday.addingTimeInterval(7 * 86400)
        #expect(Self.slots(changes, on: nextWeek).map(\.isCancelled) == [false, false])
    }

    @Test func oneMeetingMovesRoomWhileTheOtherIsCancelled() throws {
        let changes = try Self.changes([
            Self.row(1, "room", periods: ["2", "3", "4"], values: ["room": "TR-313"]),
            Self.row(2, "cancelled", periods: ["7", "8"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots.map(\.periods) == [["2", "3", "4"], ["7", "8"]])
        #expect(slots.map(\.isCancelled) == [false, true])
        #expect(slots.map(\.room) == ["TR-313", "T4-501"])
    }

    @Test func aNewStartAndEndMoveTheirMeetingAndKeepTheTimetableTimes() throws {
        let changes = try Self.changes([
            Self.row(1, "start", periods: ["2", "3", "4"], values: ["start": "09:40"]),
            Self.row(2, "end", periods: ["2", "3", "4"], values: ["end": "12:40"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots[0].start == Self.at("09:40"))
        #expect(slots[0].end == Self.at("12:40"))
        #expect(slots[0].originalStart == Self.at("09:10"))
        #expect(slots[0].originalEnd == Self.at("12:10"))
        #expect(slots[1].start == Self.at("14:20"))
        #expect(slots[1].originalStart == nil)
        #expect(slots[1].originalEnd == nil)
    }

    @Test func aChangeOverPartOfAMeetingSplitsIt() throws {
        let changes = try Self.changes([Self.row(1, "cancelled", periods: ["4"])])

        let slots = Self.slots(changes)
        #expect(slots.map(\.id) == ["CC900_20261105_2", "CC900_20261105_4", "CC900_20261105_7"])
        #expect(slots.map(\.isCancelled) == [false, true, false])
        #expect(slots[0].end == Self.at("11:10"))
    }

    @Test func aNoteRidesOnTheMeetingsItTouchesWithoutSplittingThem() throws {
        let changes = try Self.changes([
            Self.row(1, "note", periods: ["3"], values: ["note_zh": "帶筆電", "note_en": "Bring a laptop"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots.map(\.periods) == [["2", "3", "4"], ["7", "8"]])
        #expect(slots[0].notes.map(\.noteEn) == ["Bring a laptop"])
        #expect(slots[1].notes.isEmpty)
        #expect(!slots[0].isCancelled)
    }

    @Test func aCancelledSlotIdReadsAsSkipped() throws {
        let changes = try Self.changes([Self.row(1, "cancelled", periods: ["7", "8"])])
        let courses = [Self.course()]

        #expect(CourseTimeSlot.isSkipped(slotId: "CC900_20261105_7", in: courses, changes: changes))
        #expect(!CourseTimeSlot.isSkipped(slotId: "CC900_20261105_2", in: courses, changes: changes))
        #expect(!CourseTimeSlot.isSkipped(slotId: "CC900_20261112_7", in: courses, changes: changes))
    }

    @Test func theLiveActivityPassesOverACancelledClassAndShowsTheChangedRoomAndStart() throws {
        let changes = try Self.changes([
            Self.row(1, "cancelled", periods: ["2", "3", "4"]),
            Self.row(2, "room", periods: ["7", "8"], values: ["room": "TR-313"]),
            Self.row(3, "start", periods: ["7", "8"], values: ["start": "14:00"]),
        ])
        let timeline = CourseTimeSlot.buildMultiDaySlots(
            from: [Self.course()], centerDate: Self.thursday, dayRadius: 1, changes: changes
        )

        let resolver = CourseTimelineResolver()
        if case .inClass = resolver.nonSkippedState(at: Self.at("10:00"), in: timeline) {
            Issue.record("a cancelled meeting reads as in class")
        }
        let next = try #require(LiveActivityScenarioResolver.nextNonSkippedSlot(in: timeline, after: Self.thursday))
        #expect(next.id == "CC900_20261105_7")
        let snapshot = LiveActivityScenarioResolver.classPreparingSnapshot(slot: next, accentHex: 0)
        #expect(snapshot.locationText == "TR-313")
        #expect(snapshot.countdownTarget == Self.at("14:00"))
    }

    @Test func theScheduleSentToTheServerSkipsACancelledClassAndUsesTheChangedStart() {
        let data = Self.feed([
            Self.row(1, "cancelled", periods: ["7", "8"]),
            Self.row(2, "start", periods: ["2", "3", "4"], values: ["start": "10:00"]),
            Self.row(3, "room", periods: ["2", "3", "4"], values: ["room": "TR-313"]),
        ])
        let inputs = ScheduleSyncService.Inputs(
            courses: [Self.course()], assignments: [], accentHex: 0,
            classPreparingLeadTime: 15 * 60, assignmentLeadTime: 3600,
            showClassPreparing: true, showInClass: true, showAssignmentScenario: false,
            liveActivityAvailable: true,
            term: CourseSelectionService.semesterCode(on: Self.thursday, calendar: .empty)
        )

        let events = Self.withStoredFeed(data) {
            ScheduleSyncService.buildEvents(
                inputs: inputs, now: Self.thursday, horizonEnd: Self.thursday.addingTimeInterval(48 * 3600)
            )
        }

        #expect(Set(events.map(\.sourceId)) == ["CC900_20261105_2"])
        #expect(events.first { $0.scenario == .inClass }?.fireAt == Self.at("10:00"))
        #expect(events.first { $0.scenario == .classPreparing }?.fireAt == Self.at("09:45"))
        #expect(events.allSatisfy { $0.snapshot.locationText == "TR-313" })
    }

    @Test func theClassTableRunsAWeekFromToday() {
        let wednesday = Self.thursday.addingTimeInterval(-86400 + 6 * 3600)
        let shown = (1...7).map { ClassTableViewModel.columnDate(weekday: $0, today: wednesday) }

        #expect(shown.map { SharedTaipei.dayKey(for: $0) } == [
            "2026-11-09", "2026-11-10", "2026-11-04", "2026-11-05", "2026-11-06", "2026-11-07", "2026-11-08",
        ])
        #expect(shown.allSatisfy { $0 == AppConstants.taipeiCalendar.startOfDay(for: $0) })
    }

    @Test func aMeetingIsCancelledOnlyWhenEveryPeriodOfItIs() throws {
        let partly = try Self.changes([
            Self.row(1, "cancelled", periods: ["4"]),
            Self.row(2, "room", periods: ["3"], values: ["room": "TR-313"]),
        ])
        let whole = try Self.changes([
            Self.row(1, "cancelled"),
            Self.row(2, "start", periods: ["7", "8"], values: ["start": "14:40"]),
        ])
        let morning = ["2", "3", "4"]

        let kept = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: morning, on: Self.thursday, changes: partly))
        #expect(!kept.isCancelled)
        #expect(kept.periods == morning)
        #expect(kept.start == Self.at("09:10") && kept.end == Self.at("12:10"))
        #expect(kept.hasChangedRoom && kept.room == "TR-313")
        let gone = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: morning, on: Self.thursday, changes: whole))
        #expect(gone.isCancelled && !gone.hasChangedRoom && !gone.hasChangedTime)
        let afternoon = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: ["7", "8"], on: Self.thursday, changes: whole))
        #expect(afternoon.hasChangedTime && afternoon.start == Self.at("14:40") && afternoon.end == Self.at("16:20"))
        #expect(CourseTimeSlot.changedMeetings(of: Self.course(), on: Self.thursday, changes: partly).map(\.periods) == [morning])
    }

    @Test func theChangesListShowsUpcomingDaysEarliestFirstAndAtMostEight() throws {
        let thursdays = (-1...9).map { offset in
            SharedTaipei.dayKey(for: Self.thursday.addingTimeInterval(Double(offset) * 7 * 86400))
        }
        let changes = try Self.changes(
            thursdays.reversed().enumerated().map { Self.row($0.offset, "cancelled", days: [$0.element]) }
                + [Self.row(99, "room", days: ["2026-11-06"], values: ["room": "TR-313"])]
        )

        let rows = CourseTimeSlot.upcomingChanges(of: Self.course(), from: Self.at("23:00"), changes: changes)
        #expect(rows.map { SharedTaipei.dayKey(for: $0.day) } == Array(thursdays[1...8]))
        #expect(rows.allSatisfy { $0.meetings.count == 2 && $0.meetings.allSatisfy { $0.isCancelled } })
    }

    @Test func theTimeLineCrossesAPeriodByItsShareAndSitsInTheGapBetweenTwo() {
        let periods = [(start: 490, end: 540), (start: 550, end: 600), (start: 800, end: 850)]
        func offset(_ minute: Int) -> CGFloat? {
            TimetableGridView.nowLineOffset(minute: minute, periods: periods, rowPitch: 55, cellHeight: 52)
        }

        #expect(offset(489) == nil)
        #expect(offset(515) == 26)
        #expect(offset(545) == 53.5)
        #expect(offset(700) == 108.5)
        #expect(offset(825) == 136)
        #expect(offset(851) == nil)
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
