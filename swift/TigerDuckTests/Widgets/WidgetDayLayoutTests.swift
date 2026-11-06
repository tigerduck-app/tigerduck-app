import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct WidgetDayLayoutTests {
    private typealias Fixtures = WidgetFixtures

    private func rows(at hour: Int, _ minute: Int) -> [WidgetClassRow] {
        let now = Fixtures.wednesday(hour, minute)
        return WidgetDayLayout.rows(snapshot: Fixtures.snapshot(), on: now, now: now)
    }

    @Test func eachClassIsPastOnOrToComeAtNow() throws {
        let rows = rows(at: 11, 32)
        #expect(rows.map(\.row.course.displayName) == ["工程數學", "資料結構與演算法", "計算機網路概論", "體育－羽球", "通識：科技、社會與永續發展導論"])
        #expect(rows[0].phase == .past)
        let progress = try #require(rows[1].progress)
        #expect(abs(progress - 72.0 / 110.0) < 0.001)
        #expect(rows[2...].allSatisfy { $0.phase == .upcoming })
    }

    @Test func aClassIsOverAtItsEnd() {
        let rows = rows(at: 12, 10)
        #expect(rows[1].phase == .past)
        #expect(rows[2].phase == .upcoming)
    }

    @Test func aCancelledClassIsNeverOn() {
        let now = Fixtures.wednesday(11, 0)
        var courses = Fixtures.week()
        let index = courses.firstIndex { $0.courseNo == "CS2001" }!
        let cancelled = SnapshotCourseChange(
            day: TaipeiTime.dayKey(for: now), periods: ["3", "4"], cancelled: true, room: nil, start: nil, end: nil
        )
        let old = courses[index]
        courses[index] = SnapshotCourse(
            courseNo: old.courseNo, displayName: old.displayName, classroom: old.classroom, schedule: old.schedule,
            colorHex: old.colorHex, changes: [cancelled], meetingChanges: [cancelled]
        )
        let rows = WidgetDayLayout.rows(snapshot: Fixtures.snapshot(courses: courses), on: now, now: now)
        #expect(rows[1].row.isCancelled)
        #expect(rows[1].phase == .upcoming)
        #expect(WidgetDayLayout.nowLine(rows: rows, now: now) == 11 * 60)
    }

    @Test func anotherDaysClassesAreAllPastOrAllToCome() {
        let now = Fixtures.wednesday(11, 32)
        let tomorrow = TaipeiTime.calendar.date(byAdding: .day, value: 1, to: now)!
        let yesterday = TaipeiTime.calendar.date(byAdding: .day, value: -1, to: now)!
        #expect(WidgetDayLayout.rows(snapshot: Fixtures.snapshot(), on: tomorrow, now: now).allSatisfy { $0.phase == .upcoming })
        #expect(WidgetDayLayout.rows(snapshot: Fixtures.snapshot(), on: yesterday, now: now).allSatisfy { $0.phase == .past })
    }

    @Test func theNowLineShowsOnlyBetweenClasses() {
        #expect(WidgetDayLayout.nowLine(rows: rows(at: 11, 32), now: Fixtures.wednesday(11, 32)) == nil)
        #expect(WidgetDayLayout.nowLine(rows: rows(at: 12, 40), now: Fixtures.wednesday(12, 40)) == 12 * 60 + 40)
        #expect(WidgetDayLayout.nowLine(rows: rows(at: 7, 30), now: Fixtures.wednesday(7, 30)) == nil)
        #expect(WidgetDayLayout.nowLine(rows: rows(at: 19, 0), now: Fixtures.wednesday(19, 0)) == nil)
    }

    @Test func theTimelineSpansTheWholeHoursOfTheDaysClasses() {
        #expect(WidgetDayLayout.hours(of: rows(at: 9, 0)) == 8...18)
        #expect(WidgetDayLayout.hours(of: []) == nil)
    }

    @Test func aListTooShortForTheDayDropsPastClassesFirst() {
        let rows = rows(at: 14, 0)
        #expect(WidgetDayLayout.window(rows, limit: 5).map(\.row.course.courseNo) == rows.map(\.row.course.courseNo))
        #expect(WidgetDayLayout.window(rows, limit: 3).map(\.row.course.courseNo) == ["CS3001", "PE1001", "GE1001"])
        #expect(WidgetDayLayout.window(rows, limit: 4).map(\.row.course.courseNo) == ["CS2001", "CS3001", "PE1001", "GE1001"])
        let late = self.rows(at: 20, 0)
        #expect(WidgetDayLayout.window(late, limit: 2).map(\.row.course.courseNo) == ["PE1001", "GE1001"])
    }

    @Test func ticksFallEveryFiveMinutesOverTheTimelineAfterNow() {
        let now = Fixtures.wednesday(17, 2)
        let ticks = WidgetDayLayout.ticks(snapshot: Fixtures.snapshot(), after: now)
        #expect(ticks.first == Fixtures.wednesday(17, 5))
        #expect(ticks.last == Fixtures.wednesday(18, 0))
        #expect(ticks.count == 12)
        #expect(WidgetDayLayout.ticks(snapshot: Fixtures.snapshot(courses: []), after: now).isEmpty)
    }

    @Test func theWeekNumberFollowsTheTermTheSnapshotCarries() {
        #expect(Fixtures.snapshot().term?.week(on: Fixtures.wednesday(9, 0)) == 9)
        #expect(Fixtures.snapshot(term: nil).term == nil)
    }

    @Test func aSnapshotWrittenBeforeTheTermWasAddedStillDecodes() throws {
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Fixtures.snapshot())) as! [String: Any]
        json.removeValue(forKey: "term")
        let decoded = try JSONDecoder().decode(WidgetSnapshot.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.term == nil)
        #expect(decoded.courses.count == Fixtures.week().count)
    }
}
