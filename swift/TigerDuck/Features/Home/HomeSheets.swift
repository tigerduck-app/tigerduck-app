import Foundation

/// The course sheet and assignment page Home shows. An assignment opened from the course sheet
/// waits for the sheet to close before its page opens.
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
