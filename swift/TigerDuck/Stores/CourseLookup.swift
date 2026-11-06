import Foundation

enum CourseLookup {
    typealias Syllabus = CourseSyllabus

    static func syllabus(semester: String, courseNo: String, language: String) async throws -> Syllabus? {
        try await CourseLookupService.syllabus(semester: semester, courseNo: courseNo, language: language)
    }

    nonisolated static func schedule(of meetingCodes: String?) -> [Int: [String]] {
        CourseLookupService.parseNodeToSchedule(meetingCodes)
    }

    static func moodleCourseId(idnumber: String) -> Int? {
        MoodleFiles.shared.lookupMoodleCourseId(idnumber: idnumber)
    }

    static func moodleCourseId(idnumber: String?, in ids: [String: Int]) -> Int? {
        MoodleFiles.moodleCourseId(idnumber: idnumber, in: ids)
    }

    /// Every Moodle course id stored, by its Moodle id number.
    static func moodleCourseIds() -> [String: Int] {
        MoodleFiles.shared.loadMoodleCourseIdMap()
    }

    static func replaceMoodleCourseIds(of courses: [MoodleEnrolledCourse], for signIn: SignIn) {
        MoodleFiles.shared.replaceMoodleCourseIdMap(
            AssignmentRecords.moodleCourseIdMap(courses), enrolled: Set(courses.map(\.id)), for: signIn
        )
    }
}
