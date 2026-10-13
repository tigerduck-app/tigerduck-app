import Foundation

/// A course's summary on Moodle, with the course's names there, which tell a summary of its own
/// from one that only repeats them.
nonisolated struct MoodleCourseSummary: Codable, Sendable, Equatable {
    /// HTML, already through Moodle's text filters.
    let html: String
    /// The summary as one line of text, kept with it so the sheet does not parse HTML as it draws.
    let text: String
    /// The course's full, display and short names, and its idnumber where Moodle gives it.
    let names: [String]

    /// A course without a summary, or on a site that does not allow the call.
    static let empty = MoodleCourseSummary(html: "", text: "", names: [])

    /// Whether the summary says something the course detail does not: it has a letter or Han
    /// character, and it is not just a name of the course or one of `codes`, ignoring case and
    /// spaces. An NTUST course's summary can be its idnumber and nothing else.
    func isWorthShowing(besides codes: [String]) -> Bool {
        guard text.contains(where: \.isLetter) else { return false }
        let summary = Self.comparable(text)
        return !(names + codes).contains { Self.comparable($0) == summary }
    }

    private static func comparable(_ text: String) -> String {
        text.filter { !$0.isWhitespace }.lowercased()
    }
}

/// `core_course_get_courses_by_field` for a course's summary. The call takes the token, so the
/// caller runs it inside `MoodleWebserviceClient.withToken`.
nonisolated enum MoodleCourseSummaryService {
    static let coursesFunction = "core_course_get_courses_by_field"

    /// ``MoodleCourseSummary/empty`` when Moodle does not list the course, as for one the account
    /// cannot see. `moodlewssettingfilter` runs the text through the site's filters, as the Moodle
    /// app asks for text it shows.
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
