import Foundation
import Testing
import TigerDuckCore

// 2026-11-02 is a Monday. Times are Taipei; CI runs in UTC, so each date is built in Taipei.
struct ClassTimelineTests {
    private static let monday = "2026-11-02"

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0, second: Int = 0) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute, second: second))!
    }

    private func meeting(
        _ course: String, weekday: Int = 1, _ periods: [String], _ start: String, _ end: String,
        room: String = "TR-313", skipped: Set<String> = [], changes: [ClassChange] = []
    ) -> ClassMeeting {
        ClassMeeting(
            courseKey: course, weekday: weekday, periods: periods,
            start: ClassTimeline.minutes(of: start)!, end: ClassTimeline.minutes(of: end)!,
            room: room, skippedDays: skipped, changes: changes
        )
    }

    private func change(_ day: String, _ periods: [String], _ start: String, _ end: String, room: String = "TR-313", cancelled: Bool = false) -> ClassChange {
        ClassChange(
            day: day, periods: periods, start: ClassTimeline.minutes(of: start)!, end: ClassTimeline.minutes(of: end)!,
            room: room, isCancelled: cancelled
        )
    }

    @Test func aDayHoldsItsWeekdaysMeetingsEarliestFirst() {
        let timeline = ClassTimeline(meetings: [
            meeting("B", ["3", "4"], "10:20", "12:10"),
            meeting("A", ["1", "2"], "08:10", "10:00"),
            meeting("C", weekday: 2, ["1"], "08:10", "09:00"),
        ])
        #expect(timeline.classes(on: at(2, 12)).map(\.meeting) == [1, 0])
        #expect(timeline.classes(on: at(3, 12)).map(\.meeting) == [2])
        #expect(timeline.classes(on: at(4, 12)).isEmpty)
        let first = timeline.classes(on: at(2, 23, 59))[0]
        #expect(first.start == at(2, 8, 10))
        #expect(first.end == at(2, 10, 0))
        #expect(first.room == "TR-313")
        #expect(first.change == nil)
    }

    @Test func aSkippedOrQuietDayDropsItsClasses() {
        let meetings = [meeting("A", ["1"], "08:10", "09:00", skipped: [Self.monday]), meeting("B", ["2"], "09:10", "10:00")]
        #expect(ClassTimeline(meetings: meetings).classes(on: at(2, 8)).map(\.meeting) == [1])
        #expect(ClassTimeline(meetings: meetings).classes(on: at(9, 8)).map(\.meeting) == [0, 1])
        #expect(ClassTimeline(meetings: meetings, quietDays: [Self.monday]).classes(on: at(2, 8)).isEmpty)
    }

    @Test func aChangedMeetingRunsAsItsClassesThatDayOnly() {
        let changed = meeting("A", ["1", "2", "3"], "08:10", "11:10", changes: [
            change(Self.monday, ["3"], "10:20", "11:10", room: "IB-101"),
            change(Self.monday, ["1", "2"], "08:10", "10:00", cancelled: true),
        ])
        let timeline = ClassTimeline(meetings: [changed])
        let today = timeline.classes(on: at(2, 7))
        #expect(today.map(\.change) == [1, 0])
        #expect(today.map(\.isCancelled) == [true, false])
        #expect(today[1].room == "IB-101")
        #expect(today[1].periods == ["3"])
        #expect(timeline.classes(on: at(9, 7)).map(\.change) == [nil])
    }

    @Test func aChangedTimeCanPutALaterClassFirst() {
        let timeline = ClassTimeline(meetings: [
            meeting("A", ["1"], "08:10", "09:00", changes: [change(Self.monday, ["1"], "13:20", "14:10")]),
            meeting("B", ["3"], "10:20", "11:10"),
        ])
        #expect(timeline.classes(on: at(2, 7)).map(\.meeting) == [1, 0])
    }

    @Test func aClassIsOnFromItsStartUntilJustBeforeItsEnd() {
        let timeline = ClassTimeline(meetings: [meeting("A", ["1"], "08:10", "09:00"), meeting("B", ["2"], "09:10", "10:00")])
        func current(_ time: Date) -> Int? { timeline.nowAndNext(at: time).current?.meeting }
        func next(_ time: Date) -> Int? { timeline.nowAndNext(at: time).next?.meeting }
        #expect(current(at(2, 8, 9, second: 59)) == nil)
        #expect(next(at(2, 8, 9, second: 59)) == 0)
        #expect(current(at(2, 8, 10)) == 0)
        #expect(next(at(2, 8, 10)) == 1)
        #expect(current(at(2, 8, 59, second: 59)) == 0)
        #expect(current(at(2, 9, 0)) == nil)
        #expect(next(at(2, 9, 0)) == 1)
        #expect(timeline.nowAndNext(at: at(2, 9, 30)).day == .today)
    }

    @Test func theNextClassMayBeAnotherOneAlreadyOn() {
        let timeline = ClassTimeline(meetings: [meeting("A", ["1", "2"], "08:10", "10:00"), meeting("B", ["2"], "09:10", "10:00")])
        let result = timeline.nowAndNext(at: at(2, 9, 30))
        #expect(result.current?.meeting == 0)
        #expect(result.next?.meeting == 1)
    }

    @Test func aCancelledClassIsNeitherOnNorNext() {
        let timeline = ClassTimeline(meetings: [
            meeting("A", ["1"], "08:10", "09:00", changes: [change(Self.monday, ["1"], "08:10", "09:00", cancelled: true)]),
            meeting("B", ["2"], "09:10", "10:00"),
        ])
        let result = timeline.nowAndNext(at: at(2, 8, 30))
        #expect(result.current == nil)
        #expect(result.next?.meeting == 1)
    }

    @Test func withNothingLeftTodayTheNextClassDayIsFound() {
        let meetings = [meeting("A", ["1"], "08:10", "09:00"), meeting("B", weekday: 3, ["2"], "09:10", "10:00")]
        let timeline = ClassTimeline(meetings: meetings, quietDays: ["2026-11-04"])
        let afterMonday = timeline.nowAndNext(at: at(2, 18))
        #expect(afterMonday.current == nil)
        #expect(afterMonday.next?.meeting == 0)
        #expect(afterMonday.next?.start == at(9, 8, 10))
        #expect(afterMonday.day == .later(weekday: 1))
        let sunday = ClassTimeline(meetings: meetings).nowAndNext(at: at(1, 20))
        #expect(sunday.day == .tomorrow)
        #expect(sunday.next?.start == at(2, 8, 10))
    }

    @Test func aCurrentClassWithNothingAfterItDoesNotLookAhead() {
        let timeline = ClassTimeline(meetings: [meeting("A", ["1"], "08:10", "09:00"), meeting("B", weekday: 2, ["1"], "08:10", "09:00")])
        let result = timeline.nowAndNext(at: at(2, 8, 30))
        #expect(result.current?.meeting == 0)
        #expect(result.next == nil)
        #expect(result.day == .today)
    }

    @Test func aWeekWithoutClassesHasNoNextClass() {
        let timeline = ClassTimeline(meetings: [meeting("A", ["1"], "08:10", "09:00", skipped: ["2026-11-09"])])
        let result = timeline.nowAndNext(at: at(2, 18))
        #expect(result.current == nil)
        #expect(result.next == nil)
        #expect(result.day == .today)
    }

    @Test func boundariesAreTheStartsAndEndsStillAhead() {
        let timeline = ClassTimeline(meetings: [
            meeting("A", ["1"], "08:10", "09:00"),
            meeting("B", weekday: 2, ["2"], "09:10", "10:00"),
            meeting("C", weekday: 3, ["1"], "08:10", "09:00"),
        ])
        #expect(timeline.boundaries(after: at(2, 8, 30), days: 2) == [at(2, 9), at(3, 9, 10), at(3, 10)])
    }

    @Test func runningAndNextPickFromAnyClasses() {
        struct Slot: TimedClass, Equatable { let start: Date; let end: Date }
        let first = Slot(start: at(2, 8, 10), end: at(2, 9))
        let second = Slot(start: at(2, 9, 10), end: at(2, 10))
        let tied = Slot(start: at(2, 9, 10), end: at(2, 11))
        #expect(ClassTimeline.running(at: at(2, 9), in: [first, second]).isEmpty)
        #expect(ClassTimeline.running(at: at(2, 9), in: [first, second], includingEnd: true) == [first])
        #expect(ClassTimeline.next(after: at(2, 8, 30), in: [tied, second, first]) == tied)
        #expect(ClassTimeline.next(after: at(2, 9, 10), in: [first, second]) == nil)
    }

    @Test func stateNamesThePreviousAndNextClasses() {
        struct Slot: TimedClass, Equatable { let start: Date; let end: Date }
        let first = Slot(start: at(2, 8, 10), end: at(2, 9))
        let second = Slot(start: at(2, 9, 10), end: at(2, 10))
        let slots = [first, second]
        #expect(ClassTimeline.state(at: at(2, 7), in: slots) == .beforeFirst(next: first))
        #expect(ClassTimeline.state(at: at(2, 8, 30), in: slots) == .inClass([first]))
        #expect(ClassTimeline.state(at: at(2, 9), in: slots) == .between(previous: first, next: second))
        #expect(ClassTimeline.state(at: at(2, 9), in: slots, includingEnd: true) == .inClass([first]))
        #expect(ClassTimeline.state(at: at(2, 11), in: slots) == .afterLast(previous: second))
        #expect(ClassTimeline.state(at: at(2, 11), in: [Slot]()) == .between(previous: nil, next: nil))
    }

    @Test func periodsSplitIntoRunsOfConsecutivePeriods() {
        let order = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "A", "B", "C", "D"]
        #expect(ClassTimeline.runs(of: ["4", "1", "2", "6"], order: order) == [["1", "2"], ["4"], ["6"]])
        #expect(ClassTimeline.runs(of: ["10", "A", "9"], order: order) == [["9", "10", "A"]])
        #expect(ClassTimeline.runs(of: ["Z", "1", "Y"], order: order) == [["1"], ["Z"], ["Y"]])
        #expect(ClassTimeline.runs(of: [], order: order).isEmpty)
    }

    @Test func timesAndWeekdaysReadAsTaipeiDoes() {
        #expect(ClassTimeline.minutes(of: "08:10") == 490)
        #expect(ClassTimeline.minutes(of: "8:10") == 490)
        #expect(ClassTimeline.minutes(of: "0810") == nil)
        #expect(ClassTimeline.minutes(of: "") == nil)
        #expect(ClassTimeline.weekday(of: at(2, 0)) == 1)
        #expect(ClassTimeline.weekday(of: at(1, 23, 59)) == 7)
        #expect(ClassTimeline.weekday(of: at(7, 12)) == 6)
    }
}
