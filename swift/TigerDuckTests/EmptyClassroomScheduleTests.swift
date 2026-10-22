import Foundation
import Testing
@testable import TigerDuck

struct EmptyClassroomScheduleTests {
    private static let calendar = AppConstants.taipeiCalendar

    private static func time(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func day(_ month: Int, _ day: Int) -> Date {
        time(month, day, 0)
    }

    private static func isTeachingDay(_ date: Date) -> Bool {
        !EmptyClassroomSchedule.isWeekend(date) && !calendar.isDate(date, inSameDayAs: day(10, 26))
    }

    private static func opens(at now: Date, on day: Date, period: Int) -> Bool {
        let opening = EmptyClassroomSchedule.opening(at: now, horizon: 13, isTeachingDay: isTeachingDay)
        return opening.day == day && opening.period == period
    }

    @Test("during a period it opens on that period, and in a break on the next")
    func periodsAndBreaks() {
        let wednesday = Self.day(10, 14)
        #expect(Self.opens(at: Self.time(10, 14, 10, 30), on: wednesday, period: 2))
        #expect(Self.opens(at: Self.time(10, 14, 10, 5), on: wednesday, period: 2))
        #expect(Self.opens(at: Self.time(10, 14, 10), on: wednesday, period: 2))
        #expect(Self.opens(at: Self.time(10, 14, 7), on: wednesday, period: 0))
        #expect(Self.opens(at: Self.time(10, 14, 21, 30), on: wednesday, period: 13))
    }

    @Test("after period D it opens on the next day's first period")
    func afterTheLastPeriod() {
        #expect(Self.opens(at: Self.time(10, 14, 22), on: Self.day(10, 15), period: 0))
    }

    @Test("from Friday night it skips the weekend to Monday")
    func fridayNight() {
        let monday = Self.day(10, 19)
        #expect(Self.opens(at: Self.time(10, 16, 23), on: monday, period: 0))
        #expect(Self.opens(at: Self.time(10, 17, 10), on: monday, period: 0))
        #expect(Self.opens(at: Self.time(10, 18, 23), on: monday, period: 0))
    }

    @Test("a holiday is passed over like a weekend")
    func holiday() {
        let tuesday = Self.day(10, 27)
        #expect(Self.opens(at: Self.time(10, 23, 22, 30), on: tuesday, period: 0))
        #expect(Self.opens(at: Self.time(10, 26, 10), on: tuesday, period: 0))
    }

    @Test("with no teaching day ahead it stays on today")
    func noTeachingDayAhead() {
        let saturday = Self.day(10, 17)
        let opening = EmptyClassroomSchedule.opening(at: Self.time(10, 17, 10), horizon: 13, isTeachingDay: { _ in false })
        #expect(opening.day == saturday)
        #expect(opening.period == 2)
        #expect(EmptyClassroomSchedule.nextTeachingDay(after: saturday, horizon: 13, isTeachingDay: { _ in false }) == nil)
    }

    @Test("the periods that have ended, and the one in progress or next")
    func now() {
        #expect(EmptyClassroomSchedule.endedPeriods(at: Self.time(10, 14, 7)) == 0)
        #expect(EmptyClassroomSchedule.endedPeriods(at: Self.time(10, 14, 10, 5)) == 2)
        #expect(EmptyClassroomSchedule.endedPeriods(at: Self.time(10, 14, 22, 30)) == 14)
        #expect(EmptyClassroomSchedule.upcomingPeriod(at: Self.time(10, 14, 7)) == 0)
        #expect(EmptyClassroomSchedule.upcomingPeriod(at: Self.time(10, 14, 10, 45)) == 2)
        #expect(EmptyClassroomSchedule.upcomingPeriod(at: Self.time(10, 14, 22, 30)) == nil)
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private static let fall = AcademicCalendar(
        revision: 1,
        terms: [SemesterTerm(code: "1151", start: day(9, 14), end: date(2027, 1, 15))],
        holidays: [Holiday(id: 1, nameZh: "假日", nameEn: "Holiday", start: day(10, 26), end: day(10, 26))]
    )

    private static func dayOff(_ day: Date, in calendar: AcademicCalendar) -> EmptyClassroomSchedule.DayOff? {
        EmptyClassroomSchedule.dayOff(day, holidays: calendar.holidays(on:), isInSession: { calendar.isInSession(on: $0) })
    }

    @Test("a weekday in the term without a holiday is a teaching day, and any other day says why not")
    func daysOff() {
        #expect(Self.dayOff(Self.day(10, 14), in: Self.fall) == nil)
        #expect(Self.dayOff(Self.date(2027, 1, 15), in: Self.fall) == nil)
        #expect(Self.dayOff(Self.day(10, 17), in: Self.fall) == .weekend)
        #expect(Self.dayOff(Self.day(10, 18), in: Self.fall) == .weekend)
        #expect(Self.dayOff(Self.day(10, 26), in: Self.fall) == .holiday(Self.fall.holidays[0]))
        #expect(Self.dayOff(Self.day(9, 11), in: Self.fall) == .outOfTerm)
        #expect(Self.dayOff(Self.date(2027, 1, 18), in: Self.fall) == .outOfTerm)
        #expect(Self.dayOff(Self.date(2027, 1, 18), in: .empty) == nil)
    }

    @Test("the next teaching day passes over the weeks between terms")
    func betweenTerms() {
        let spring = SemesterTerm(code: "1152", start: Self.date(2027, 2, 22), end: Self.date(2027, 6, 18))
        let year = AcademicCalendar(revision: 1, terms: Self.fall.terms + [spring], holidays: [])
        let isTeachingDay: (Date) -> Bool = { Self.dayOff($0, in: year) == nil }

        #expect(EmptyClassroomSchedule.nextTeachingDay(after: Self.date(2027, 1, 15), horizon: 13, isTeachingDay: isTeachingDay) == nil)
        #expect(EmptyClassroomSchedule.nextTeachingDay(after: Self.date(2027, 2, 12), horizon: 13, isTeachingDay: isTeachingDay) == Self.date(2027, 2, 22))
        let opening = EmptyClassroomSchedule.opening(at: Self.date(2027, 2, 17, hour: 10), horizon: 13, isTeachingDay: isTeachingDay)
        #expect(opening.day == Self.date(2027, 2, 22))
        #expect(opening.period == 0)
    }
}
