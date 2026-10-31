import Foundation
import Observation
import TigerDuckCore

/// The days the empty-classroom screen offers and the account's classes on them: today by the
/// clock, the term's holidays and teaching days, and the class table.
@Observable
@MainActor
final class EmptyClassroomCalendar {
    @ObservationIgnored let rawRoom: @MainActor (String) -> String
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let holidays: @MainActor (Date) -> [Holiday]
    @ObservationIgnored private let isInSession: @MainActor (Date) -> Bool
    @ObservationIgnored private let isClassDay: @MainActor (Date) -> Bool
    @ObservationIgnored private let loadCourses: @MainActor () -> [SDCourse]
    @ObservationIgnored private var courses: [SDCourse] = []
    private let minuteTicker: MinuteTicker

    init(
        clock: @escaping () -> Date = { AppClock.now() },
        holidays: (@MainActor (Date) -> [Holiday])? = nil,
        isInSession: (@MainActor (Date) -> Bool)? = nil,
        isClassDay: (@MainActor (Date) -> Bool)? = nil,
        courses: (@MainActor () -> [SDCourse])? = nil,
        rawRoom: (@MainActor (String) -> String)? = nil
    ) {
        self.clock = clock
        self.holidays = holidays ?? { AcademicCalendarStore.shared.calendar.holidays(on: $0) }
        self.isInSession = isInSession ?? { AcademicCalendarStore.shared.calendar.isInSession(on: $0) }
        self.isClassDay = isClassDay ?? { AcademicCalendarStore.shared.isClassDay($0) }
        loadCourses = courses ?? { CanonicalCourseProvider().currentCourses() }
        self.rawRoom = rawRoom ?? { NameAbbrService.shared.rawClassroom($0) }
        minuteTicker = MinuteTicker(now: clock)
    }

    /// The time, read again at each new minute by whoever observes it.
    var now: Date {
        _ = minuteTicker.tick
        return clock()
    }

    /// The time without observing the minute.
    var instant: Date { clock() }

    func dayOff(_ day: Date) -> EmptyClassroomSchedule.DayOff? {
        EmptyClassroomSchedule.dayOff(day, holidays: holidays, isInSession: isInSession)
    }

    func isTeachingDay(_ day: Date) -> Bool {
        dayOff(day) == nil
    }

    func reloadCourses() {
        courses = loadCourses()
    }

    func classSlots(on day: Date) -> [CourseTimeSlot] {
        CourseTimeSlot.meetingSlots(from: courses, on: day, isClassDay: isClassDay)
    }
}
