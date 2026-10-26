import Foundation

nonisolated struct CourseSearchResult: Codable {
    let Semester: String
    let CourseNo: String
    let CourseName: String
    let CourseTeacher: String
    let Dimension: String?
    let CreditPoint: String
    let RequireOption: String?
    let AllYear: String?
    let ChooseStudent: Int?
    let Restrict1: String?
    let Restrict2: String?
    let CourseTimes: String?
    let PracticalTimes: String?
    let ClassRoomNo: String?
    let Node: String?
    let Contents: String?
}

struct CourseSearchRequest: Codable, Equatable {
    let Semester: String
    let CourseNo: String
    let CourseName: String
    let CourseTeacher: String
    let Dimension: String
    let CourseNotes: String
    let CampusNotes: String
    let ForeignLanguage: Int
    let OnlyGeneral: Int
    let OnleyNTUST: Int
    let OnlyMaster: Int
    let OnlyUnderGraduate: Int
    let OnlyNode: Int
    let OnlyIntensive: Int
    let Language: String

    static func forCourseNo(_ courseNo: String, semester: String, language: String = "zh") -> CourseSearchRequest {
        CourseSearchRequest(
            Semester: semester,
            CourseNo: courseNo,
            CourseName: "",
            CourseTeacher: "",
            Dimension: "",
            CourseNotes: "",
            CampusNotes: "",
            ForeignLanguage: 0,
            OnlyGeneral: 0,
            OnleyNTUST: 0,
            OnlyMaster: 0,
            OnlyUnderGraduate: 0,
            OnlyNode: 0,
            OnlyIntensive: 0,
            Language: language
        )
    }
}

/// The department and GE type lists of the Add Course filters, from the term's catalog.
struct CourseSearchOptions: Codable, Equatable {
    struct Option: Codable, Hashable {
        let code: String
        let name: String
        let englishName: String

        func name(in language: String) -> String { language == "en" ? englishName : name }
    }

    struct College: Codable, Equatable {
        let name: String
        let englishName: String
        let departments: [Option]

        func name(in language: String) -> String { language == "en" ? englishName : name }
    }

    var colleges: [College] = []
    var dimensions: [Option] = []
}

/// One course's syllabus from QueryCourse's `coursedetials`. Any field may be null or blank, and
/// an alliance course carries little more than a link to the other school's page.
nonisolated struct CourseSyllabus: Codable, Hashable, Sendable {
    let CourseGrading: String?
    let CourseObject: String?
    let CourseContent: String?
    let CourseTextbook: String?
    let CourseRefbook: String?
    let CourseNote: String?
    let CoreAbility: String?
    let CourseURL: String?
}

nonisolated extension CourseSyllabus {
    var grading: String? { Self.text(CourseGrading) }
    var outline: String? { Self.text(CourseObject) }
    var method: String? { Self.text(CourseContent) }
    var notes: String? { Self.text(CourseNote) }
    var objectives: String? { Self.text(CoreAbility) }

    var references: String? {
        let books = [CourseTextbook, CourseRefbook].compactMap(Self.text)
        return books.isEmpty ? nil : books.joined(separator: "\n\n")
    }

    var website: URL? {
        guard let text = Self.text(CourseURL), let url = URL(string: text),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    var hasContent: Bool {
        [grading, outline, method, references, notes, objectives].contains { $0 != nil } || website != nil
    }

    private static func text(_ value: String?) -> String? {
        let text = value?.replacingOccurrences(of: "\r\n", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }
}
