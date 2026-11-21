import Foundation

func spokenCourse(
    _ course: CourseStore.Course, isAssessment: Bool = false, room: String? = nil, changes: [String] = [],
    hasAssignment: Bool, ignoresAssignments: Bool
) -> String {
    var parts = [course.displayName]
    if isAssessment { parts.append(String(localized: "course_change_assessment")) }
    if let room { parts.append(room) }
    parts += changes
    if hasAssignment { parts.append(String(localized: "a11y_class_table_cell_assignment_indicator")) }
    if ignoresAssignments { parts.append(String(localized: "a11y_class_table_cell_assignments_ignored")) }
    return parts.joined(separator: ", ")
}
