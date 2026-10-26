import Foundation
import Testing
@testable import TigerDuck

struct MoodleCurrentWeekTests {
    private static let calendar = AppConstants.taipeiCalendar

    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 10, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private static func sections(_ names: [String]) -> [MoodleMaterialSection] {
        names.enumerated().map { MoodleMaterialSection(id: 100 + $0.offset, name: $0.element, materials: [], number: $0.offset) }
    }

    private static func current(
        _ sections: [MoodleMaterialSection], format: String? = "topics", start: Date? = nil, now: Date
    ) -> Int? {
        MoodleCurrentWeek.sectionId(in: sections, format: format, startDate: start, now: now, calendar: calendar)
    }

    private static let weekly = sections(["General", "Week 1", "Week 2", "Week 3", "Week 4"])
    private static let weeklyStart = date(2026, 9, 7, 0)

    @Test("a weekly course counts weeks from its start date, section 1 being the first, each from the start's weekday")
    func weeklyCountsFromTheStart() {
        #expect(Self.current(Self.weekly, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 7, 0)) == 101)
        #expect(Self.current(Self.weekly, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 20, 23, 59)) == 102)
        #expect(Self.current(Self.weekly, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 21, 0)) == 103)
        #expect(Self.current(Self.weekly, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 10, 4)) == 104)
    }

    @Test("a weekly course has no current section before it starts, after its last section, or in a week whose section is not listed")
    func weeklyWithoutItsWeek() {
        #expect(Self.current(Self.weekly, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 6, 23, 59)) == nil)
        #expect(Self.current(Self.weekly, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 10, 5)) == nil)
        let withoutWeek2 = Self.weekly.filter { $0.number != 2 }
        #expect(Self.current(withoutWeek2, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 16)) == nil)
    }

    @Test("a weekly course goes by its section numbers, not its names, and a cache without numbers gives none")
    func weeklyGoesByNumber() {
        let named = Self.sections(["General", "Intro 12/1", "Sockets 12/8"])
        #expect(Self.current(named, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 15)) == 102)
        let unnumbered = Self.weekly.map { MoodleMaterialSection(id: $0.id, name: $0.name, materials: []) }
        #expect(Self.current(unnumbered, format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 15)) == nil)
    }

    @Test("a course of another format, or a weekly one without a start date, goes by the dates in its section names")
    func otherFormatsGoByNames() {
        let names = Self.sections(["課程資訊", "第1週 9/8 Introduction", "第2週 9/15 HTTP", "第3週 9/22 TCP"])
        #expect(Self.current(names, now: Self.date(2026, 9, 16)) == 102)
        #expect(Self.current(names, format: "weeks", start: nil, now: Self.date(2026, 9, 22)) == 103)
        #expect(Self.current(names, format: nil, now: Self.date(2026, 9, 8, 0)) == 101)
    }

    @Test("a name may write its date as month and day in Chinese, or after a year")
    func dateStyles() {
        let chinese = Self.sections(["General", "9月8日 課程介紹", "9 月 15 日 HTTP"])
        #expect(Self.current(chinese, now: Self.date(2026, 9, 18)) == 102)
        let withYear = Self.sections(["General", "2026/09/08 Intro", "2026/09/15 HTTP"])
        #expect(Self.current(withYear, now: Self.date(2026, 9, 10)) == 101)
    }

    @Test("a section's dates run a week from its first date, or to the end of a longer range, and stop at the next dated section")
    func sectionSpan() {
        let names = Self.sections(["General", "11/2-11/15 Midterm", "11/16 Routing", "11/18 Switching", "11/30 Review"])
        #expect(Self.current(names, now: Self.date(2026, 11, 12)) == 101)
        #expect(Self.current(names, now: Self.date(2026, 11, 17)) == 102)
        #expect(Self.current(names, now: Self.date(2026, 11, 24)) == 103)
        #expect(Self.current(names, now: Self.date(2026, 11, 25)) == nil)
        #expect(Self.current(names, now: Self.date(2026, 12, 6)) == 104)
        #expect(Self.current(names, now: Self.date(2026, 12, 7)) == nil)
        #expect(Self.current(names, now: Self.date(2026, 11, 1)) == nil)
    }

    @Test("a term across New Year puts its December sections in the year before its January ones")
    func acrossNewYear() {
        let names = Self.sections(["General", "Week 15 12/21", "Week 16 12/28-1/3", "Week 17 1/4", "Week 18 1/11 Final"])
        #expect(Self.current(names, now: Self.date(2026, 12, 23)) == 101)
        #expect(Self.current(names, now: Self.date(2027, 1, 2)) == 102)
        #expect(Self.current(names, now: Self.date(2027, 1, 5)) == 103)
        #expect(Self.current(names, now: Self.date(2027, 1, 12)) == 104)
        let early = Self.sections(["General", "9/14 Intro", "1/11 Final"])
        #expect(Self.current(early, now: Self.date(2026, 9, 15)) == 101)
        #expect(Self.current(early, now: Self.date(2027, 1, 12)) == 102)
    }

    @Test("names without dates, with dates that do not rise, or with no real date give no section")
    func noWeek() {
        #expect(Self.current(Self.weekly, now: Self.date(2026, 9, 16)) == nil)
        let falling = Self.sections(["General", "Part 3/4", "Part 1/2", "Part 2/2"])
        #expect(Self.current(falling, now: Self.date(2026, 3, 5)) == nil)
        let impossible = Self.sections(["General", "2/30 Intro", "13/1 Lab"])
        #expect(Self.current(impossible, now: Self.date(2026, 3, 1)) == nil)
        #expect(Self.current([], format: "weeks", start: Self.weeklyStart, now: Self.date(2026, 9, 8)) == nil)
    }
}
