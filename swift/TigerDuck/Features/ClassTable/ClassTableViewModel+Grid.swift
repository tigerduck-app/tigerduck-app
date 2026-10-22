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
        selectedCourse = course
    }

    func selectOngoing(_ info: OngoingCourseInfo) {
        selectedWeekday = info.weekday
        selectedPeriodId = info.firstPeriodId
        selectedCoursePeriods = info.periods
        selectedCourse = info.course
    }

}
