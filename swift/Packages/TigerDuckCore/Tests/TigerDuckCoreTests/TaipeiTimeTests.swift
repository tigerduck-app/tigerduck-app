import Foundation
import Testing
import TigerDuckCore

// CI runs in UTC, eight hours behind Taipei, so each case sits where the two zones disagree.
struct TaipeiTimeTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func utcDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    @Test func theZoneIsTaipeiAtEightHoursAheadOfUTC() {
        #expect(TaipeiTime.timeZone.identifier == "Asia/Taipei")
        #expect(TaipeiTime.timeZone.secondsFromGMT(for: utcDate(2026, 7, 1, 0)) == 8 * 3600)
        #expect(TaipeiTime.calendar.identifier == .gregorian)
        #expect(TaipeiTime.calendar.timeZone == TaipeiTime.timeZone)
    }

    @Test func aLateUTCEveningIsTheNextDayInTaipei() {
        let date = utcDate(2026, 10, 31, 16, 30)
        #expect(TaipeiTime.dayKey(for: date) == "2026-11-01")
        #expect(TaipeiTime.calendar.component(.weekday, from: date) == 1)
        #expect(TaipeiTime.calendar.component(.hour, from: date) == 0)
    }

    @Test func theDayStartsAtTaipeiMidnight() {
        let start = TaipeiTime.calendar.startOfDay(for: utcDate(2026, 10, 31, 3))
        #expect(start == utcDate(2026, 10, 30, 16))
    }

    @Test func theDayKeyPadsMonthAndDayAndChangesAtTaipeiMidnight() {
        #expect(TaipeiTime.dayKey(for: utcDate(2027, 1, 4, 15, 59)) == "2027-01-04")
        #expect(TaipeiTime.dayKey(for: utcDate(2027, 1, 4, 16, 0)) == "2027-01-05")
    }

    @Test func addingADayFollowsTheTaipeiCalendar() {
        let next = TaipeiTime.calendar.date(byAdding: .day, value: 1, to: utcDate(2026, 12, 31, 20))!
        #expect(TaipeiTime.dayKey(for: next) == "2027-01-02")
    }
}
