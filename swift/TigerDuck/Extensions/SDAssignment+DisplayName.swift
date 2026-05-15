import Foundation

extension SDAssignment {
    /// Course label to render in assignment cells, notification bodies, and
    /// Live Activity rows. Respects the user's course-rename override
    /// (`SDCourse.customName`) so a renamed course keeps its alias on every
    /// assignment surface, not just the class table. Falls back to the API
    /// course name embedded in the assignment when no override exists.
    ///
    /// The lookup reads `DataCache.loadCourseCustomNames()` (a JSON dict on
    /// disk). Dict is keyed by courseNo and typically a handful of entries
    /// — a single read per render is fine.
    var displayCourseName: String {
        let overrides = DataCache.shared.loadCourseCustomNames()
        return overrides[courseNo] ?? courseName
    }
}
