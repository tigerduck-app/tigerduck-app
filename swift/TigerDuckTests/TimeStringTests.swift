import Foundation
import Testing
@testable import TigerDuck

struct TimeStringTests {
    private static func taipei(_ hour: Int, _ minute: Int) -> Date {
        AppConstants.taipeiCalendar.date(
            from: DateComponents(year: 2026, month: 10, day: 13, hour: hour, minute: minute)
        )!
    }

    @Test("a 12-hour locale reads an evening time on a 24-hour clock")
    func twelveHourLocale() {
        var style = Date.timeStyle
        style.locale = Locale(identifier: "en_US")
        #expect(Self.taipei(20, 3).formatted(style) == "20:03")
        #expect(Self.taipei(0, 5).formatted(style) == "00:05")
    }

    @Test("a locale with digits of its own still reads 20:03")
    func westernDigits() {
        #expect(Self.taipei(20, 3).timeString == "20:03")
        #expect(Self.taipei(20, 3).moodleListDateString(now: Self.taipei(9, 0)) == "20:03")
    }

    @Test("the time is Taipei's, zero-padded, on a 24-hour clock")
    func taipeiTime() {
        #expect(Self.taipei(20, 3).timeString == "20:03")
        #expect(Self.taipei(8, 10).timeString == "08:10")
        #expect(Self.taipei(0, 5).timeString == "00:05")
    }
}
