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
        let raw: String
        if let course, course.courseNo == courseNo {
            raw = course.displayName
        } else {
            let overrides = DataCache.shared.loadCourseCustomNames()
            raw = overrides[courseNo] ?? courseName
        }
        return raw.decodingHTMLEntities()
    }

    /// Convenience for callers without course context. Prefer
    /// `displayCourseName(matching:)` when the canonical course list is
    /// already in scope.
    var displayCourseName: String { displayCourseName(matching: nil) }

    /// HTML-decoded title for display. Moodle sometimes returns titles like
    /// `Assignment 1 &amp; 2`; rendering the raw string would expose the
    /// encoded entity to the user.
    var displayTitle: String { title.decodingHTMLEntities() }

    /// "課名 • 課程ID" line shown beneath each assignment title. Prefers the
    /// in-memory `SDCourse` so user renames and the canonical NTUST code are
    /// reflected; otherwise the cached `courseName` keeps the row useful while
    /// the roster is still loading. The code is dropped when it's empty or
    /// already equal to the name (unknown courses whose name falls back to
    /// the courseNo).
    func courseLineLabel(matching course: SDCourse?) -> String {
        let name = displayCourseName(matching: course)
        let code = course?.courseNo ?? courseNo
        if code.isEmpty || name.isEmpty || name == code {
            return name
        }
        return "\(name) • \(code)"
    }
}
