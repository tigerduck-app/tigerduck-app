import Foundation
import Testing
import TigerDuckCore

struct QuietDayCalendarTests {
    private func day(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func span(_ start: Date, _ end: Date) -> QuietDayCalendar.Span {
        QuietDayCalendar.Span(start: start, end: end)
    }

    private var autumn: QuietDayCalendar.Span { span(day(2026, 9, 14), day(2027, 1, 8)) }
    private var spring: QuietDayCalendar.Span { span(day(2027, 2, 22), day(2027, 6, 18)) }
    private var nationalDay: QuietDayCalendar.Holiday { .init(id: 7, span: span(day(2026, 10, 9), day(2026, 10, 10))) }

    @Test func aDayIsInSessionWithinATermBothEndsIncluded() {
        let calendar = QuietDayCalendar(terms: [autumn, spring], holidays: [])
        #expect(!calendar.isInSession(day(2026, 9, 13, 23)))
        #expect(calendar.isInSession(day(2026, 9, 14)))
        #expect(calendar.isInSession(day(2027, 1, 8, 23)))
        #expect(!calendar.isInSession(day(2027, 1, 9)))
        #expect(QuietDayCalendar(terms: [], holidays: []).isInSession(day(2027, 1, 9)))
    }

    @Test func aHolidayTakesClassesUnlessTheUserKeepsThem() {
        let calendar = QuietDayCalendar(terms: [autumn], holidays: [nationalDay])
        #expect(calendar.suppressesClasses(on: day(2026, 10, 10, 18)))
        #expect(!calendar.isClassDay(day(2026, 10, 9)))
        #expect(calendar.isClassDay(day(2026, 10, 12)))
        let kept = QuietDayCalendar(terms: [autumn], holidays: [nationalDay], optedIn: [7])
        #expect(!kept.suppressesClasses(on: day(2026, 10, 10)))
        #expect(kept.isClassDay(day(2026, 10, 10)))
    }

    @Test func aKeptHolidayOverlappingAnotherKeepsTheClasses() {
        let bridge = QuietDayCalendar.Holiday(id: 8, span: span(day(2026, 10, 10), day(2026, 10, 11)))
        let calendar = QuietDayCalendar(terms: [autumn], holidays: [nationalDay, bridge], optedIn: [8])
        #expect(calendar.suppressesClasses(on: day(2026, 10, 9)))
        #expect(!calendar.suppressesClasses(on: day(2026, 10, 10)))
    }

    @Test func quietKeysCoverDaysOutOfSessionAndHolidays() {
        let calendar = QuietDayCalendar(terms: [autumn, spring], holidays: [nationalDay])
        let keys = calendar.quietDayKeys(from: day(2026, 9, 1, 9), days: 373)
        #expect(keys.contains("2026-09-01"))
        #expect(keys.contains("2026-09-13"))
        #expect(!keys.contains("2026-09-14"))
        #expect(keys.contains("2026-10-09"))
        #expect(keys.contains("2026-10-10"))
        #expect(!keys.contains("2027-01-08"))
        #expect(keys.contains("2027-01-09"))
        #expect(!keys.contains("2027-02-22"))
        #expect(keys.contains("2027-06-19"))
    }

    @Test func outOfSessionKeysStopAtTheHorizonButHolidaysDoNot() {
        let ended = QuietDayCalendar(terms: [span(day(2026, 2, 16), day(2026, 6, 19))], holidays: [nationalDay])
        let keys = ended.quietDayKeys(from: day(2027, 10, 13, 9), days: 373)
        #expect(keys.count == 375)
        #expect(keys.contains("2026-10-10"))
        #expect(keys.subtracting(["2026-10-09", "2026-10-10"]).min() == "2027-10-13")
        #expect(keys.max() == "2028-10-19")
        #expect(QuietDayCalendar(terms: [], holidays: []).quietDayKeys(from: day(2027, 10, 13), days: 373).isEmpty)
    }
}
