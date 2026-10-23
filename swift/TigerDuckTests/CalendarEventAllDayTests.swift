import Foundation
import Testing
@testable import TigerDuck

@Suite("Calendar event all-day")
struct CalendarEventAllDayTests {

    private static let midnight = AppConstants.taipeiCalendar.date(
        from: DateComponents(year: 2026, month: 9, day: 14)
    )!
    private static let afternoon = midnight.addingTimeInterval(14 * 3600)

    private static func event(_ source: EventSource, at date: Date) -> SDCalendarEvent {
        SDCalendarEvent(eventId: "event", title: "Event", date: date, source: source)
    }

    @Test("holidays and term boundaries are whole days")
    func holidaysAndTermBoundariesAreWholeDays() {
        #expect(Self.event(.holiday, at: Self.midnight).isAllDay)
        #expect(Self.event(.semester, at: Self.afternoon).isAllDay)
    }

    @Test("a school-calendar row is a whole day only at midnight in Taipei")
    func schoolRowIsAWholeDayOnlyAtMidnight() {
        #expect(Self.event(.school, at: Self.midnight).isAllDay)
        #expect(!Self.event(.school, at: Self.afternoon).isAllDay)
    }

    @Test("a Moodle deadline at midnight keeps its time")
    func moodleDeadlineAtMidnightKeepsItsTime() {
        #expect(!Self.event(.moodle, at: Self.midnight).isAllDay)
    }

    @MainActor @Test("the iPhone day list shows no time on a whole day's row")
    func theDayListShowsNoTimeOnAWholeDay() {
        #expect(!EventRowView.showsTime(of: Self.event(.semester, at: Self.midnight)))
        #expect(!EventRowView.showsTime(of: Self.event(.school, at: Self.midnight)))
        #expect(EventRowView.showsTime(of: Self.event(.school, at: Self.afternoon)))
        #expect(EventRowView.showsTime(of: Self.event(.moodle, at: Self.midnight)))
    }
}
