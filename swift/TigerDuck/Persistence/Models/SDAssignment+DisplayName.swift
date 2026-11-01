import Foundation

extension SDAssignment {
    func displayCourseName(matching course: SDCourse?) -> String {
        let raw: String
        if let course, course.courseNo == courseNo {
            raw = course.displayName
        } else {
            let overrides = CourseStore.shared.loadCourseCustomNamesFlat()
            raw = overrides[courseNo] ?? courseName
        }
        return raw.decodingHTMLEntities()
    }

    var displayCourseName: String { displayCourseName(matching: nil) }

    var displayTitle: String { title.decodingHTMLEntities() }

    func courseLineLabel(matching course: SDCourse?) -> String {
        let name = displayCourseName(matching: course)
        let code = course?.courseNo ?? courseNo
        if code.isEmpty || name.isEmpty || name == code {
            return name
        }
        return "\(name) • \(code)"
    }
}
