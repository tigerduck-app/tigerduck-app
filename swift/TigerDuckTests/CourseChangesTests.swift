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

    @Test func meetingSlotsLeaveOutACancelledMeeting() throws {
        let changes = try Self.changes([Self.row(1, "cancelled", periods: ["2", "3", "4"])])

        let slots = CourseTimeSlot.meetingSlots(
            from: [Self.course()], on: Self.thursday, isClassDay: { _ in true }, changes: changes
        )
        #expect(slots.map(\.periods) == [["7", "8"]])
    }

    @Test func aRoomChangeOverPartOfAMovedMeetingSplitsItWithoutOverlap() throws {
        let changes = try Self.changes([
            Self.row(1, "start", periods: ["2", "3", "4"], values: ["start": "10:00"]),
            Self.row(2, "end", periods: ["2", "3", "4"], values: ["end": "13:00"]),
            Self.row(3, "room", periods: ["4"], values: ["room": "TR-313"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots.map(\.periods) == [["2", "3"], ["4"], ["7", "8"]])
        #expect(slots.map(\.start) == [Self.at("10:00"), Self.at("11:20"), Self.at("14:20")])
        #expect(slots.map(\.end) == [Self.at("11:10"), Self.at("13:00"), Self.at("16:20")])
        #expect(slots.map(\.room) == ["T4-501", "TR-313", "T4-501"])
    }

    enum MatrixTime: CaseIterable, Sendable { case none, start, end, both, invalidStart }
    enum MatrixPartial: CaseIterable, Sendable { case none, room, cancellation, both }

    private static func timetable(_ period: String, end: Bool) -> Date {
        let times = AppConstants.PeriodTimes.mapping[period]!
        return Self.at(end ? times.end : times.start)
    }

    /// A three-period meeting under every mix of a whole-meeting time change and a change to
    /// some of its periods, as fragments, as one meeting and as the classes that meet.
    @Test(arguments: MatrixTime.allCases, MatrixPartial.allCases)
    func aMeetingCombinesItsTimeAndItsPartialChanges(time: MatrixTime, partial: MatrixPartial) throws {
        var rows: [[String: Any]] = []
        if time == .start || time == .both { rows.append(Self.row(1, "start", values: ["start": "09:40"])) }
        if time == .end || time == .both { rows.append(Self.row(2, "end", values: ["end": "11:50"])) }
        if time == .invalidStart { rows.append(Self.row(1, "start", values: ["start": "13:00"])) }
        if partial == .room || partial == .both { rows.append(Self.row(3, "room", periods: ["4"], values: ["room": "TR-313"])) }
        if partial == .cancellation || partial == .both { rows.append(Self.row(4, "cancelled", periods: ["2"])) }
        let changes = try Self.changes(rows)
        let course = SDCourse(courseNo: "CC900", courseName: "Compilers", classroom: "T4-501", schedule: [4: ["2", "3", "4"]])
        let start = time == .start || time == .both ? Self.at("09:40") : Self.at("09:10")
        let end = time == .end || time == .both ? Self.at("11:50") : Self.at("12:10")
        let pieces: [(periods: [String], cancelled: Bool, room: String)] = switch partial {
        case .none: [(["2", "3", "4"], false, "T4-501")]
        case .room: [(["2", "3"], false, "T4-501"), (["4"], false, "TR-313")]
        case .cancellation: [(["2"], true, "T4-501"), (["3", "4"], false, "T4-501")]
        case .both: [(["2"], true, "T4-501"), (["3"], false, "T4-501"), (["4"], false, "TR-313")]
        }

        let fragments = CourseTimeSlot.buildSlots(from: [course], weekday: 4, on: Self.thursday, changes: changes)
        #expect(fragments.map(\.periods) == pieces.map(\.periods))
        #expect(fragments.map(\.isCancelled) == pieces.map(\.cancelled))
        #expect(fragments.map(\.room) == pieces.map(\.room))
        #expect(fragments.first?.start == start && fragments.last?.end == end)
        for (left, right) in zip(fragments, fragments.dropFirst()) {
            #expect(left.end == Self.timetable(left.periods[left.periods.count - 1], end: true))
            #expect(right.start == Self.timetable(right.periods[0], end: false))
        }

        let meeting = try #require(CourseTimeSlot.meeting(of: course, periods: ["2", "3", "4"], on: Self.thursday, changes: changes))
        #expect(meeting.periods == ["2", "3", "4"])
        #expect(meeting.start == start && meeting.end == end)
        #expect(meeting.originalStart == (start == Self.at("09:10") ? nil : Self.at("09:10")))
        #expect(meeting.originalEnd == (end == Self.at("12:10") ? nil : Self.at("12:10")))
        #expect(!meeting.isCancelled)
        #expect(meeting.room == (partial == .room || partial == .both ? "TR-313" : "T4-501"))

        let meets = CourseTimeSlot.meetingSlots(from: [course], on: Self.thursday, isClassDay: { _ in true }, changes: changes)
        #expect(meets.map(\.periods) == pieces.filter { !$0.cancelled }.map(\.periods))
    }

    @Test func aFragmentTheNewTimesLeaveEmptyIsDropped() throws {
        let changes = try Self.changes([
            Self.row(1, "start", periods: ["2", "3", "4"], values: ["start": "10:30"]),
            Self.row(2, "cancelled", periods: ["2"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots.map(\.periods) == [["3", "4"], ["7", "8"]])
        #expect(slots.first?.start == Self.at("10:30") && slots.first?.end == Self.at("12:10"))
        let meeting = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: ["2"], on: Self.thursday, changes: changes))
        #expect(meeting.periods == ["2", "3", "4"] && !meeting.isCancelled)
        #expect(meeting.start == Self.at("10:30") && meeting.originalStart == Self.at("09:10"))
    }

    @Test func aDroppedOuterFragmentLeavesTheMeetingTimesOnTheNextOne() throws {
        let changes = try Self.changes([
            Self.row(1, "start", periods: ["2", "3", "4"], values: ["start": "10:05"]),
            Self.row(2, "end", periods: ["7", "8"], values: ["end": "15:15"]),
            Self.row(3, "room", periods: ["3", "4", "7"], values: ["room": "TR-313"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots.map(\.periods) == [["3", "4"], ["7"]])
        #expect(slots.map(\.start) == [Self.at("10:05"), Self.at("14:20")])
        #expect(slots.map(\.end) == [Self.at("12:10"), Self.at("15:15")])
        #expect(slots.map(\.originalStart) == [Self.at("10:20"), nil])
        #expect(slots.map(\.originalEnd) == [nil, Self.at("15:10")])
        let moved = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: ["3"], on: Self.thursday, changes: changes))
        #expect(moved.start == Self.at("10:05") && moved.end == Self.at("12:10"))
        let shortened = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: ["7"], on: Self.thursday, changes: changes))
        #expect(shortened.start == Self.at("14:20") && shortened.end == Self.at("15:15"))
    }

    @Test func aTimeChangeThatWouldEndBeforeItStartsIsDroppedButTheRestStays() throws {
        let changes = try Self.changes([
            Self.row(1, "start", periods: ["2", "3", "4"], values: ["start": "15:00"]),
            Self.row(2, "room", periods: ["2", "3", "4"], values: ["room": "TR-313"]),
            Self.row(3, "end", periods: ["7", "8"], values: ["end": "13:00"]),
            Self.row(4, "cancelled", periods: ["7", "8"]),
        ])

        let slots = Self.slots(changes)
        #expect(slots.map(\.start) == [Self.at("09:10"), Self.at("14:20")])
        #expect(slots.map(\.end) == [Self.at("12:10"), Self.at("16:20")])
        #expect(slots.map(\.hasChangedTime) == [false, false])
        #expect(slots.map(\.room) == ["TR-313", "T4-501"])
        #expect(slots.map(\.isCancelled) == [false, true])
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
        #expect(snapshot.roomChanged == true && snapshot.timeChanged == true)
        let plain = CourseTimeSlot.buildSlots(from: [Self.course()], weekday: 4, on: Self.thursday, changes: .empty)[0]
        let json = try String(decoding: JSONEncoder().encode(
            LiveActivityScenarioResolver.classPreparingSnapshot(slot: plain, accentHex: 0)
        ), as: UTF8.self)
        #expect(!json.contains("roomChanged") && !json.contains("timeChanged"))
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

    @Test func aMergedMeetingSpansItsPartsAndKeepsTheTimetableOrder() throws {
        let later = try Self.changes([Self.row(1, "end", periods: ["3"], values: ["end": "13:00"])])
        let earlier = try Self.changes([Self.row(1, "start", periods: ["3"], values: ["start": "08:30"])])
        let morning = ["2", "3", "4"]

        let longer = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: morning, on: Self.thursday, changes: later))
        #expect(longer.periods == morning)
        #expect(longer.start == Self.at("09:10") && longer.end == Self.at("13:00"))
        #expect(longer.originalStart == nil && longer.originalEnd == Self.at("12:10"))
        let sooner = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: morning, on: Self.thursday, changes: earlier))
        #expect(sooner.periods == morning)
        #expect(sooner.start == Self.at("08:30") && sooner.end == Self.at("12:10"))
        #expect(sooner.originalStart == Self.at("09:10") && sooner.originalEnd == nil)
    }

    @Test func theChangesListShowsUpcomingDaysEarliestFirstAndAtMostEight() throws {
        let thursdays = (-1...9).map { offset in
            SharedTaipei.dayKey(for: Self.thursday.addingTimeInterval(Double(offset) * 7 * 86400))
        }
        let changes = try Self.changes(
            thursdays.reversed().enumerated().map { Self.row($0.offset, "cancelled", days: [$0.element]) }
                + [Self.row(99, "room", days: ["2026-11-06"], values: ["room": "TR-313"])]
        )

        let days = CourseTimeSlot.upcomingChanges(of: Self.course(), from: Self.at("23:00"), changes: changes)
        #expect(days.map { SharedTaipei.dayKey(for: $0.day) } == Array(thursdays[1...]))
        #expect(days.allSatisfy { $0.meetings.count == 2 && $0.meetings.allSatisfy { $0.isCancelled } })
        let rows = CourseDetailSheet.changeRows(days, besides: nil)
        #expect(rows.map { SharedTaipei.dayKey(for: $0.day) } == Array(thursdays[1...8]))
        #expect(rows.allSatisfy { $0.summary == String(localized: "course_card_cancelled") })
    }

    @Test func theChangesListLeavesTheShownMeetingsRoomAndTimeToTheCards() throws {
        let changes = try Self.changes([
            Self.row(1, "room", periods: ["2", "3", "4"], values: ["room": "TR-313"]),
            Self.row(2, "start", periods: ["7", "8"], days: ["2026-11-12"], values: ["start": "14:40"]),
            Self.row(3, "note", periods: ["7"], days: ["2026-11-12"], values: ["note_zh": "Quiz"]),
        ])
        let days = CourseTimeSlot.upcomingChanges(of: Self.course(), from: Self.thursday, changes: changes)
        let today = try #require(CourseTimeSlot.meeting(of: Self.course(), periods: ["2", "3", "4"], on: Self.thursday, changes: changes))
        let nextWeek = try #require(days.last?.meetings.first)

        #expect(CourseDetailSheet.changeRows(days, besides: nil).map { $0.summary } == ["TR-313", "14:40 - 16:20 · Quiz"])
        #expect(CourseDetailSheet.changeRows(days, besides: today).map { $0.summary } == ["14:40 - 16:20 · Quiz"])
        #expect(CourseDetailSheet.changeRows(days, besides: nextWeek).map { $0.summary } == ["TR-313", "Quiz"])
    }

    @Test func aTappedClassShowsItsOwnChangesWhileATimetableBlockShowsItsMeeting() throws {
        let changes = try Self.changes([
            Self.row(1, "cancelled", periods: ["2"]),
            Self.row(2, "room", periods: ["4"], values: ["room": "TR-313"]),
        ])
        let slots = Self.slots(changes)
        #expect(slots.map(\.periods) == [["2"], ["3"], ["4"], ["7", "8"]])
        func shown(_ slot: CourseTimeSlot?, periods: [String]? = nil) -> CourseTimeSlot? {
            CourseDetailSheet.shownMeeting(of: Self.course(), slot: slot, periods: periods, on: Self.thursday, changes: changes)
        }

        #expect(shown(slots[0])?.isCancelled == true)
        #expect(shown(slots[1]) == nil)
        #expect(shown(slots[2])?.room == "TR-313")
        let block = try #require(shown(nil, periods: ["2", "3", "4"]))
        #expect(block.periods == ["2", "3", "4"] && !block.isCancelled && block.room == "TR-313")
        let days = CourseTimeSlot.upcomingChanges(of: Self.course(), from: Self.thursday, changes: changes)
        #expect(CourseDetailSheet.changeRows(days, besides: shown(slots[2])).isEmpty)
        #expect(CourseDetailSheet.changeRows(days, besides: shown(slots[0])).map(\.summary) == ["TR-313"])
    }

    @Test func theCurrentClassIsTheChangedOneAndACancelledClassIsNotRunning() throws {
        let changes = try Self.changes([
            Self.row(1, "room", periods: ["2", "3", "4"], values: ["room": "TR-313"]),
            Self.row(2, "cancelled", periods: ["7", "8"]),
        ])

        let morning = try #require([Self.course()].ongoingCourses(at: Self.at("10:30"), changes: changes).first)
        #expect((morning.periods, morning.classroom) == (["2", "3", "4"], "TR-313"))
        let partly = try Self.changes([Self.row(1, "room", periods: ["4"], values: ["room": "TR-313"])])
        let piece = try #require([Self.course()].ongoingCourses(at: Self.at("10:30"), changes: partly).first)
        let viewModel = ClassTableViewModel()
        viewModel.selectOngoing(piece)
        let opened = CourseDetailSheet.shownMeeting(
            of: Self.course(), slot: viewModel.selectedSlot, periods: viewModel.selectedCoursePeriods,
            on: viewModel.selectedDate, changes: partly
        )
        #expect(piece.periods == ["2", "3"] && opened == nil)
        #expect([Self.course()].ongoingCourses(at: Self.at("14:30"), changes: changes).isEmpty)
        #expect([Self.course()].ongoingCourses(at: Self.at("14:30"), changes: .empty).count == 1)
    }

    @Test func aClassIsOverOnceTheCancelledLaterPieceOfItsMeetingBegins() throws {
        let changes = try Self.changes([Self.row(1, "cancelled", periods: ["4"])])
        let id = try #require(Self.slots(.empty).first?.id)

        #expect(CourseTimeSlot.hasEnded(slotId: id, in: [Self.course()], at: Self.at("11:30"), changes: changes))
        #expect(!CourseTimeSlot.hasEnded(slotId: id, in: [Self.course()], at: Self.at("10:30"), changes: changes))
        #expect(!CourseTimeSlot.hasEnded(slotId: id, in: [Self.course()], at: Self.at("11:30"), changes: .empty))
    }

    @Test func aClassWhoseFirstPieceAChangeDroppedEndsWithTheRestOfItsMeeting() throws {
        let changes = try Self.changes([
            Self.row(1, "start", periods: ["2", "3", "4"], values: ["start": "10:30"]),
            Self.row(2, "end", periods: ["2", "3", "4"], values: ["end": "11:00"]),
            Self.row(3, "room", periods: ["2"], values: ["room": "TR-313"]),
        ])
        let id = try #require(Self.slots(.empty).first?.id)
        #expect(Self.slots(changes).first.map(\.periods) == ["3", "4"])

        #expect(CourseTimeSlot.hasEnded(slotId: id, in: [Self.course()], at: Self.at("11:30"), changes: changes))
        #expect(!CourseTimeSlot.hasEnded(slotId: id, in: [Self.course()], at: Self.at("10:45"), changes: changes))
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
        let store = CourseChangeStore(
            session: URLSession(configuration: config), baseURL: { base }, hasCompletedOnboarding: { true }
        )
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

    @Test func aStoredFeedThisBuildCannotReadIsFetchedAgain() async throws {
        let savedCache = Defaults[.courseChangesCache]
        let savedTag = Defaults[.courseChangesETag]
        defer {
            Defaults[.courseChangesCache] = savedCache
            Defaults[.courseChangesETag] = savedTag
        }
        Defaults[.courseChangesCache] = Data("not a feed".utf8)
        Defaults[.courseChangesETag] = #"W/"a""#
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appendingPathComponent("calendar").appendingPathComponent("course-changes")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let store = CourseChangeStore(
            session: URLSession(configuration: config), baseURL: { base }, hasCompletedOnboarding: { true }
        )
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: Self.feed([Self.row(1, "cancelled")]), headerFields: ["ETag": #"W/"a""#]),
            for: url
        )

        #expect(await store.refresh())
        #expect(SettingsAPIStub.requests(for: url).map { $0.value(forHTTPHeaderField: "If-None-Match") } == [nil])
        #expect(CourseChanges.cached.changes(courseNo: "CC900", on: Self.thursday).map(\.id) == [1])
    }

    @Test func aRefreshAnEndpointChangeReplacedLeavesTheNewOneToBeJoined() async throws {
        let savedCache = Defaults[.courseChangesCache]
        let savedTag = Defaults[.courseChangesETag]
        defer {
            Defaults[.courseChangesCache] = savedCache
            Defaults[.courseChangesETag] = savedTag
        }
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appendingPathComponent("calendar").appendingPathComponent("course-changes")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let store = CourseChangeStore(
            session: URLSession(configuration: config), baseURL: { base }, hasCompletedOnboarding: { true }
        )
        let old = SettingsAPIStub.ReplyGate()
        let new = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.feed([]), gate: old), for: url)
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.feed([Self.row(1, "cancelled")]), gate: new), for: url)

        let first = Task { await store.refresh() }
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 1 }
        store.endpointDidChange()
        try await waitUntil { SettingsAPIStub.requests(for: url).count == 2 }
        old.open()
        _ = await first.value
        let joined = Task { await store.refresh() }
        new.open()

        #expect(await joined.value)
        #expect(SettingsAPIStub.requests(for: url).count == 2)
    }

    @Test func theStoreAsksNothingBeforeOnboardingEnds() async {
        let base = SettingsAPIStub.uniqueBaseURL()
        let url = base.appendingPathComponent("calendar").appendingPathComponent("course-changes")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let store = CourseChangeStore(
            session: URLSession(configuration: config), baseURL: { base }, hasCompletedOnboarding: { false }
        )
        SettingsAPIStub.enqueue(.init(statusCode: 200, body: Self.feed([Self.row(1, "cancelled")])), for: url)

        #expect(await store.refresh() == false)
        #expect(SettingsAPIStub.requests(for: url).isEmpty)
    }
}
