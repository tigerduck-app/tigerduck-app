import Foundation
import Testing
@testable import TigerDuck

/// Where the finder opens: the period in progress, the next one in a break, and the next
/// teaching day after the last period, at a weekend or on a holiday.
struct EmptyClassroomScheduleTests {
    private static let calendar = AppConstants.taipeiCalendar

    private static func time(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    private static func day(_ month: Int, _ day: Int) -> Date {
        time(month, day, 0)
    }

    /// 2026-10-26, a Monday, is a holiday.
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

    @Test("a weekday without a holiday is a teaching day")
    func teachingDays() {
        let holiday = Holiday(id: 1, nameZh: "假日", nameEn: "Holiday", start: Self.day(10, 26), end: Self.day(10, 26))
        let holidays: (Date) -> [Holiday] = { holiday.contains($0) ? [holiday] : [] }
        #expect(EmptyClassroomSchedule.isTeachingDay(Self.day(10, 14), holidays: holidays))
        #expect(!EmptyClassroomSchedule.isTeachingDay(Self.day(10, 17), holidays: holidays))
        #expect(!EmptyClassroomSchedule.isTeachingDay(Self.day(10, 18), holidays: holidays))
        #expect(!EmptyClassroomSchedule.isTeachingDay(Self.day(10, 26), holidays: holidays))
    }
}
