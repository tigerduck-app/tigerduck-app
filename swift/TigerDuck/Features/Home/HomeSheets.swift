import Foundation

struct HomeSheets {
    var selectedCourse: CourseStore.Course?
    var selectedCourseSlot: CourseTimeSlot?
    var shownAssignment: MoodleAssignmentPage?
    private var assignmentAfterSheet: MoodleAssignmentPage?

    mutating func show(_ page: MoodleAssignmentPage, closingSheet: Bool = true) {
        guard closingSheet, selectedCourse != nil else {
            shownAssignment = page
            return
        }
        assignmentAfterSheet = page
        selectedCourse = nil
    }

    mutating func courseSheetDismissed() {
        guard let page = assignmentAfterSheet else { return }
        assignmentAfterSheet = nil
        shownAssignment = page
    }

    mutating func closeAssignment() {
        assignmentAfterSheet = nil
        shownAssignment = nil
    }
}
