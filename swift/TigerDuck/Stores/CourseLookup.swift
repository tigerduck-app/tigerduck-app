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

    static func replaceMoodleCourseIds(
        _ ids: [String: Int], for signIn: SignIn,
        moodle: MoodleFiles = .shared, courses: CourseStore = .shared, colors: CourseColorStore = .shared
    ) {
        // The first map of a sign-in finds colours that may be another device's, so it moves none.
        guard let stored = moodle.replaceMoodleCourseIdMap(ids, for: signIn) else { return }
        let term = CourseSelectionService.currentSemesterCode()
        let current = courses.loadCourses(semester: term) + courses.loadUserAddedCourses(semester: term)
        let known = CourseColorStore.moodleColors(of: current, ids: stored)
        let arrived = CourseColorStore.moodleColors(of: current, ids: ids).filter { known[$0.key] == nil }
        colors.takeMoodleColors(arrived, for: signIn)
    }
}
