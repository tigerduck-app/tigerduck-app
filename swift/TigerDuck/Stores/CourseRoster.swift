import Foundation

/// What the course list knows of a course the transcript names: its teacher, seats, room and
/// meeting times.
struct CourseRoster: Equatable {
    let instructor: String
    let enrolledCount: Int
    let maxCount: Int
    let classroom: String
    let schedule: [Int: [String]]

    /// The term's own course first, else one the user added for that term or for none.
    static func find(courseNo: String, term: String, in store: CourseStore = .shared) -> CourseRoster? {
        let course = store.loadCourses(semester: term).first { $0.courseNo == courseNo }
            ?? store.loadUserAddedCourses().first {
                $0.courseNo == courseNo && ($0.semester == term || $0.semester.isEmpty)
            }
        return course.map {
            CourseRoster(
                instructor: $0.instructor, enrolledCount: $0.enrolledCount, maxCount: $0.maxCount,
                classroom: SDCourse.dedup($0.classroom), schedule: $0.schedule
            )
        }
    }
}
