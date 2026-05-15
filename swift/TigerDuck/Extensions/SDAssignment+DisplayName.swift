import Foundation

extension SDAssignment {
    /// Course label resolution with optional in-memory course context.
    ///
    /// When a caller already holds the canonical `SDCourse` (with
    /// `customName` applied in-memory), pass it via `matching:` so the
    /// label reflects the freshest alias. Without context, fall back to the
    /// on-disk override dictionary, then to the cached `courseName` on the
    /// assignment.
    ///
    /// The on-disk path reads `DataCache.loadCourseCustomNames()` (a JSON
    /// dict). It can be stale relative to in-memory `SDCourse` state — e.g.
    /// right after a rename, before persistence settles — which is why an
    /// explicit `matching` course wins when supplied.
    func displayCourseName(matching course: SDCourse?) -> String {
        if let course, course.courseNo == courseNo {
            return course.displayName
        }
        let overrides = DataCache.shared.loadCourseCustomNames()
        return overrides[courseNo] ?? courseName
    }

    /// Convenience for callers without course context. Prefer
    /// `displayCourseName(matching:)` when the canonical course list is
    /// already in scope.
    var displayCourseName: String { displayCourseName(matching: nil) }
}
