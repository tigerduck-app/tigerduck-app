import Foundation

nonisolated struct MoodleCourseSummary: Codable, Sendable, Equatable {
    let html: String
    let text: String
    let names: [String]

    static let empty = MoodleCourseSummary(html: "", text: "", names: [])

    func isWorthShowing(besides codes: [String]) -> Bool {
        guard text.contains(where: \.isLetter) else { return false }
        let summary = Self.comparable(text)
        return !(names + codes).contains { Self.comparable($0) == summary }
    }

    private static func comparable(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}

nonisolated enum MoodleCourseSummaryService {
    static let coursesFunction = "core_course_get_courses_by_field"

    static func summary(
        courseId: Int,
        token: String,
        session: URLSession = MoodleWebserviceClient.session,
        siteURL: URL = AppConstants.moodleBaseURL
    ) async throws -> MoodleCourseSummary {
        try await MoodleWebserviceClient.call(
            coursesFunction,
            params: [("field", "id"), ("value", String(courseId)), ("moodlewssettingfilter", "true")],
            token: token,
            as: RawCourses.self,
            session: session,
            siteURL: siteURL
        ).courses.first { $0.id == courseId }?.model ?? .empty
    }
}

private nonisolated struct RawCourses: Decodable, Sendable {
    let courses: [RawCourse]
}

private nonisolated struct RawCourse: Decodable, Sendable {
    let id: Int
    let fullname: String?
    let displayname: String?
    let shortname: String?
    let idnumber: String?
    let summary: String?

    var model: MoodleCourseSummary {
        let html = summary ?? ""
        return MoodleCourseSummary(
            html: html,
            text: MoodleHTMLText.plainText(fromHTML: html),
            names: [fullname, displayname, shortname, idnumber].compactMap { $0 }
                .map(MoodleHTMLText.plainText(fromHTML:))
                .filter { !$0.isEmpty }
        )
    }
}
