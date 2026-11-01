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

    /// Every Moodle course id stored, by its Moodle id number.
    static func moodleCourseIds() -> [String: Int] {
        MoodleFiles.shared.loadMoodleCourseIdMap()
    }

    static func replaceMoodleCourseIds(_ ids: [String: Int], for signIn: SignIn) {
        MoodleFiles.shared.replaceMoodleCourseIdMap(ids, for: signIn)
    }
}
