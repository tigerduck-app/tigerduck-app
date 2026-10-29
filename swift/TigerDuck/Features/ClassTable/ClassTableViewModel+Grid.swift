import Defaults
import SwiftUI

extension ClassTableViewModel {

    typealias CellRole = ClassTableCellRole<SDCourse>

    func cellRole(weekday: Int, periodIndex: Int) -> CellRole {
        let key = CellRoleKey(weekday: weekday, periodIndex: periodIndex)
        if let cached = cellRoleCache[key] { return cached }
        let role = ClassTableLayout.cellRole(
            courses: courses,
            periodIds: activePeriods.map(\.id),
            weekday: weekday,
            periodIndex: periodIndex,
            keyOf: { $0.courseNo },
            scheduleOf: { $0.schedule }
        )
        cellRoleCache[key] = role
        return role
    }

    struct ConflictPickerTarget: Identifiable {
        let id = UUID()
        let courses: [SDCourse]
        let weekday: Int
        let periodId: String
    }

    struct TripleConflictError: Identifiable {
        let id = UUID()
        let weekday: Int
        let periodId: String
        let newCourseName: String
        let existingA: SDCourse
        let existingB: SDCourse
    }

    func wouldCauseTripleConflict(_ candidate: SDCourse) -> TripleConflictError? {
        for (weekday, periodIds) in candidate.schedule {
            for pid in periodIds {
                let existing = courses(for: weekday, period: pid)
                if existing.count >= 2 {
                    return TripleConflictError(
                        weekday: weekday,
                        periodId: pid,
                        newCourseName: candidate.displayName,
                        existingA: existing[0],
                        existingB: existing[1]
                    )
                }
            }
        }
        return nil
    }

    func presentConflictPicker(courseA: SDCourse, courseB: SDCourse, weekday: Int, periodId: String) {
        conflictPickerTarget = ConflictPickerTarget(
            courses: [courseA, courseB],
            weekday: weekday,
            periodId: periodId
        )
    }

    func pickFromConflict(_ course: SDCourse) {
        guard let target = conflictPickerTarget else { return }
        let weekday = target.weekday
        let periodId = target.periodId
        conflictPickerTarget = nil
        selectCourse(course, weekday: weekday, periodId: periodId)
    }

    func selectCourse(_ course: SDCourse, weekday: Int, periodId: String) {
        selectedWeekday = weekday
        selectedPeriodId = periodId
        selectedCoursePeriods = course.block(weekday: weekday, at: periodId, in: activePeriods.map(\.id))
        selectedDate = showsThisWeek ? Self.columnDate(weekday: weekday, today: AppClock.now()) : nil
        selectedCourse = course
    }

    func selectOngoing(_ info: OngoingCourseInfo) {
        selectedDate = AppClock.now()
        selectedWeekday = info.weekday
        selectedPeriodId = info.firstPeriodId
        selectedCoursePeriods = info.periods
        selectedCourse = info.course
    }

    /// The table shows the current term as a week from today once the changes feed has answered;
    /// other terms, and every term before then, stay a plain timetable.
    var showsThisWeek: Bool {
        !courseChanges.term.isEmpty && currentSemester == CourseSelectionService.currentSemesterCode()
    }

    /// The date a weekday column shows. The week runs from today, so on a Wednesday the Monday
    /// and Tuesday columns are next week's.
    static func columnDate(weekday: Int, today: Date) -> Date {
        let calendar = AppConstants.taipeiCalendar
        let start = calendar.startOfDay(for: today)
        let ahead = (weekday - today.scheduleWeekday + 7) % 7
        return calendar.date(byAdding: .day, value: ahead, to: start) ?? start
    }

    /// The block's meeting on its column's date, or nil when the school changed nothing there.
    func changedMeeting(of course: SDCourse, weekday: Int, at periodId: String, today: Date) -> CourseTimeSlot? {
        guard showsThisWeek else { return nil }
        let date = Self.columnDate(weekday: weekday, today: today)
        guard !courseChanges.changes(courseNo: course.courseNo, on: date).isEmpty,
              let block = course.block(weekday: weekday, at: periodId, in: activePeriods.map(\.id))
        else { return nil }
        return CourseTimeSlot.meeting(of: course, periods: block, on: date, changes: courseChanges)
            .flatMap { $0.changes.isEmpty ? nil : $0 }
    }
}
