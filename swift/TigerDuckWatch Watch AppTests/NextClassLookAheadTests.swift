import Foundation
import Testing
@testable import TigerDuckWatch_Watch_App

/// With no class on and none left today, Now & Next and the complications show the first class
/// of the next class day within a week (https://github.com/tigerduck-app/tigerduck-app/issues/364).
struct NextClassLookAheadTests {

    private func course(
        _ id: String, weekday: Int, start: String, end: String, skippedDates: Set<String>? = nil
    ) -> WatchCourse {
        WatchCourse(
            id: id, courseNo: id, name: id, teacher: "",
            classroom: "", colorHex: "#FF8800",
            weekday: weekday, startHHmm: start, endHHmm: end, periodLabel: "",
            skippedDates: skippedDates
        )
    }

    /// Mon 2026-05-11 at `hhmm`, Taipei time; `dayOffset` moves to a later day.
    private func mondayAt(_ hhmm: String, dayOffset: Int = 0) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let day = DateComponents(year: 2026, month: 5, day: 11 + dayOffset, hour: parts[0], minute: parts[1])
        return SharedTaipei.calendar.date(from: day)!
    }

    private func dayKey(_ dayOffset: Int) -> String {
        SharedTaipei.dayKey(for: mondayAt("12:00", dayOffset: dayOffset))
    }

    @Test func anEveningAfterTheLastClass_givesTomorrowsFirstClass() {
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tuesdayAfternoon = course("C", weekday: 2, start: "13:30", end: "14:20")
        let tuesdayMorning = course("B", weekday: 2, start: "08:10", end: "09:00")

        let r = NextClassResolver.resolve(
            courses: [monday, tuesdayAfternoon, tuesdayMorning], now: mondayAt("18:00")
        )

        #expect(r.current == nil)
        #expect(r.next?.id == "B")
        #expect(r.nextDay == .tomorrow)
    }

    @Test func aQuietToday_givesTheNextClassDaysFirstClass() {
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let wednesday = course("C", weekday: 3, start: "08:10", end: "09:00")

        let r = NextClassResolver.resolve(courses: [monday, wednesday], now: mondayAt("10:45"), quietDays: [dayKey(0)])

        #expect(r.current == nil)
        #expect(r.next?.id == "C")
        #expect(r.nextDay == .later(weekday: 3))
    }

    @Test func quietDaysAndSkippedDatesAhead_arePassedOver() {
        let tuesday = course("B", weekday: 2, start: "08:10", end: "09:00")
        let wednesday = course("C", weekday: 3, start: "08:10", end: "09:00", skippedDates: [dayKey(2)])
        let thursday = course("D", weekday: 4, start: "10:20", end: "11:10")

        let r = NextClassResolver.resolve(
            courses: [tuesday, wednesday, thursday], now: mondayAt("18:00"), quietDays: [dayKey(1)]
        )

        #expect(r.next?.id == "D")
        #expect(r.nextDay == .later(weekday: 4))
    }

    @Test func aFridayEveningWithNoWeekendClasses_givesMondayByItsWeekday() {
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let friday = course("E", weekday: 5, start: "10:20", end: "11:10")

        let r = NextClassResolver.resolve(courses: [monday, friday], now: mondayAt("18:00", dayOffset: 4))

        #expect(r.next?.id == "A")
        #expect(r.nextDay == .later(weekday: 1))
    }

    /// Tuesday is quiet, so B next meets eight days on, past the week the look-ahead covers.
    @Test func nothingWithinSevenDays_givesNoNextClass() {
        let tuesday = course("B", weekday: 2, start: "08:10", end: "09:00")

        let r = NextClassResolver.resolve(courses: [tuesday], now: mondayAt("18:00"), quietDays: [dayKey(1)])

        #expect(r.current == nil)
        #expect(r.next == nil)
        #expect(r.nextDay == .today)
    }

    @Test func aClassStillToComeToday_staysTheNextClass() {
        let morning = course("A", weekday: 1, start: "10:20", end: "11:10")
        let afternoon = course("B", weekday: 1, start: "13:30", end: "14:20")
        let tuesday = course("C", weekday: 2, start: "08:10", end: "09:00")

        let r = NextClassResolver.resolve(courses: [morning, afternoon, tuesday], now: mondayAt("12:00"))

        #expect(r.current == nil)
        #expect(r.next?.id == "B")
        #expect(r.nextDay == .today)
    }

    @Test func duringTheDaysLastClass_nothingIsNextYet() {
        let morning = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tuesday = course("C", weekday: 2, start: "08:10", end: "09:00")

        let r = NextClassResolver.resolve(courses: [morning, tuesday], now: mondayAt("10:45"))

        #expect(r.current?.id == "A")
        #expect(r.next == nil)
        #expect(r.nextDay == .today)
    }
}
