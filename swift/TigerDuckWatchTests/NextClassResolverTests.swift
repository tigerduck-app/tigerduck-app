import XCTest
@testable import TigerDuckWatch

final class NextClassResolverTests: XCTestCase {

    private func course(_ id: String, weekday: Int, start: String, end: String) -> WatchCourse {
        WatchCourse(
            id: id, courseNo: id, name: id, teacher: "",
            classroom: "", colorHex: "#FF8800",
            weekday: weekday, startHHmm: start, endHHmm: end, periodLabel: ""
        )
    }

    /// Builds a Date for Mon 2026-05-11 at the given HH:mm in the system calendar.
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

    func test_afterLastClass_bothNil() {
        let c1 = course("A", weekday: 1, start: "10:20", end: "11:10")
        let r = NextClassResolver.resolve(courses: [c1], now: mondayAt("18:00"))
        XCTAssertNil(r.current)
        XCTAssertNil(r.next)
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

    func test_overlappingSessions_picksEarliestEnd() {
        // Defensive: real data shouldn't overlap, but lock the contract.
        let a = course("A", weekday: 1, start: "10:00", end: "11:00")
        let b = course("B", weekday: 1, start: "10:30", end: "11:30")
        let r = NextClassResolver.resolve(courses: [a, b], now: mondayAt("10:45"))
        XCTAssertEqual(r.current?.id, "A")
        XCTAssertEqual(r.next?.id, "B")
    }
}
