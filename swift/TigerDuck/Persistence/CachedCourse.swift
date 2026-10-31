import Foundation

/// A course as the course files store it. Its fields and their names are the file format.
struct CachedCourse: Codable {
    let courseNo: String
    let courseName: String
    let instructor: String
    let credits: Double
    let classroom: String
    let enrolledCount: Int
    let maxCount: Int
    let scheduleJSON: String
    let moodleIdNumber: String?
    let semester: String?
    let classroomMapJSON: String?
    let skippedDatesJSON: String?
    let dimension: String?
    let allYear: String?
    let requireOption: String?

    init(from course: SDCourse) {
        courseNo = course.courseNo
        courseName = course.courseName
        instructor = course.instructor
        credits = course.credits
        classroom = course.classroom
        enrolledCount = course.enrolledCount
        maxCount = course.maxCount
        scheduleJSON = course.scheduleJSON
        moodleIdNumber = course.moodleIdNumber
        semester = course.semester.isEmpty ? nil : course.semester
        classroomMapJSON = course.classroomMapJSON
        skippedDatesJSON = course.skippedDatesJSON
        dimension = course.dimension.isEmpty ? nil : course.dimension
        allYear = course.allYear.isEmpty ? nil : course.allYear
        requireOption = course.requireOption.isEmpty ? nil : course.requireOption
    }

    func toSDCourse() -> SDCourse {
        let schedule: [Int: [String]]
        if let data = scheduleJSON.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: [String]].self, from: data) {
            schedule = Dictionary(uniqueKeysWithValues: dict.compactMap { key, value in
                guard let intKey = Int(key) else { return nil }
                return (intKey, value)
            })
        } else {
            schedule = [:]
        }

        let classroomMap: [String: String]
        if let json = classroomMapJSON,
           let data = json.data(using: .utf8),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            classroomMap = dict
        } else {
            classroomMap = [:]
        }

        let course = SDCourse(
            courseNo: courseNo,
            courseName: courseName,
            instructor: instructor,
            credits: credits,
            classroom: classroom,
            enrolledCount: enrolledCount,
            maxCount: maxCount,
            schedule: schedule,
            moodleIdNumber: moodleIdNumber,
            semester: semester ?? CourseSelectionService.currentSemesterCode(),
            classroomMap: classroomMap,
            dimension: dimension ?? "",
            allYear: allYear ?? "",
            requireOption: requireOption ?? ""
        )
        course.skippedDatesJSON = skippedDatesJSON ?? "[]"
        return course
    }
}
