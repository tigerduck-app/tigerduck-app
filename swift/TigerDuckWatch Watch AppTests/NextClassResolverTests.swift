import XCTest
@testable import TigerDuckWatch_Watch_App

final class NextClassResolverTests: XCTestCase {

    private func course(_ id: String, weekday: Int, start: String, end: String) -> WatchCourse {
        WatchCourse(
            id: id, courseNo: id, name: id, teacher: "",
            classroom: "", colorHex: "#FF8800",
            weekday: weekday, startHHmm: start, endHHmm: end, periodLabel: ""
        )
    }

    private func mondayAt(_ hhmm: String) -> Date {
        let comps = hhmm.split(separator: ":").map(String.init)
        var dc = DateComponents()
        dc.year = 2026; dc.month = 5; dc.day = 11
        dc.hour = Int(comps[0]); dc.minute = Int(comps[1])
        return Calendar(identifier: .iso8601).date(from: dc)!
    }

    func test_beforeFirstClass_currentIsNil_nextIsFirst() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let c2 = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [c1, c2], now: mondayAt("09:00"))
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "A")
    }

    func test_duringClass_currentIsThat_nextIsAfter() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let c2 = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [c1, c2], now: mondayAt("10:45"))
        XCTAssertEqual(r.current?.id, "A")
        XCTAssertEqual(r.next?.id, "B")
    }

    func test_betweenClasses_currentIsNil_nextIsLater() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let c2 = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [c1, c2], now: mondayAt("12:00"))
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "B")
    }

    func test_afterLastClass_nextIsTheSameClassNextWeek() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let r = NextClassResolver.resolve(courses: [c1], now: mondayAt("18:00"))
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "A")
        XCTAssertEqual(r.nextDay, .later(weekday: 1))
    }

    func test_emptyCourses_bothNil() {
        let r = NextClassResolver.resolve(courses: [], now: mondayAt("10:00"))
        XCTAssertNil(r.current)
        XCTAssertNil(r.next)
    }

    func test_filtersOutOtherWeekdays() {
        let mon = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tue = course("B", weekday: 2, start: "10:20", end: "11:10")
        let r = NextClassResolver.resolve(courses: [mon, tue], now: mondayAt("09:00"))
        XCTAssertEqual(r.next?.id, "A")
    }

    func test_holiday_hidesTodaysClasses() {
        let a = course("A", weekday: 1, start: "10:20", end: "11:10")
        let now = mondayAt("10:45")
        let r = NextClassResolver.resolve(courses: [a], now: now, quietDays: [SharedTaipei.dayKey(for: now)])
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "A")
        XCTAssertEqual(r.nextDay, .later(weekday: 1))
    }

    func test_holidayOnAnotherDay_changesNothing() {
        let a = course("A", weekday: 1, start: "10:20", end: "11:10")
        let now = mondayAt("09:00")
        let tomorrow = SharedTaipei.calendar.date(byAdding: .day, value: 1, to: now)!
        let r = NextClassResolver.resolve(courses: [a], now: now, quietDays: [SharedTaipei.dayKey(for: tomorrow)])
        XCTAssertEqual(r.next?.id, "A")
    }

    func test_courseSkippedToday_isLeftOut() {
        let now = mondayAt("09:00")
        let skipped = WatchCourse(
            id: "A", courseNo: "A", name: "A", teacher: "", classroom: "", colorHex: "#FF8800",
            weekday: 1, startHHmm: "10:20", endHHmm: "11:10", periodLabel: "",
            skippedDates: [SharedTaipei.dayKey(for: now)]
        )
        let b = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.resolve(courses: [skipped, b], now: now)
        XCTAssertNil(r.current)
        XCTAssertEqual(r.next?.id, "B")
    }

    func test_todaysClasses_listsTodayInStartOrder() {
        let late = course("B", weekday: 1, start: "13:30", end: "14:20")
        let early = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tue = course("C", weekday: 2, start: "08:10", end: "09:00")
        let r = NextClassResolver.todaysClasses(courses: [late, early, tue], now: mondayAt("18:00"), quietDays: [])
        XCTAssertEqual(r.map(\.id), ["A", "B"])
    }

    func test_todaysClasses_holiday_isEmpty() {
        let a = course("A", weekday: 1, start: "10:20", end: "11:10")
        let now = mondayAt("09:00")
        let r = NextClassResolver.todaysClasses(courses: [a], now: now, quietDays: [SharedTaipei.dayKey(for: now)])
        XCTAssertTrue(r.isEmpty)
    }

    func test_todaysClasses_leavesOutACourseSkippedToday() {
        let now = mondayAt("09:00")
        let skipped = WatchCourse(
            id: "A", courseNo: "A", name: "A", teacher: "", classroom: "", colorHex: "#FF8800",
            weekday: 1, startHHmm: "10:20", endHHmm: "11:10", periodLabel: "",
            skippedDates: [SharedTaipei.dayKey(for: now)]
        )
        let b = course("B", weekday: 1, start: "13:30", end: "14:20")
        let r = NextClassResolver.todaysClasses(courses: [skipped, b], now: now, quietDays: [])
        XCTAssertEqual(r.map(\.id), ["B"])
    }

    func test_overlappingSessions_picksEarliestEnd() {
        let a = course("A", weekday: 1, start: "10:00", end: "11:00")
        let b = course("B", weekday: 1, start: "10:30", end: "11:30")
        let r = NextClassResolver.resolve(courses: [a, b], now: mondayAt("10:45"))
        XCTAssertEqual(r.current?.id, "A")
        XCTAssertEqual(r.next?.id, "B")
    }
}
