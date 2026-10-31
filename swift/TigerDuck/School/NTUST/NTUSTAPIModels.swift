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
nonisolated struct CourseSyllabus: Decodable, Hashable, Sendable {
    let CourseGrading: String?
    let CourseObject: String?
    let CourseContent: String?
    let CourseTextbook: String?
    let CourseRefbook: String?
    let CourseNote: String?
    let CoreAbility: String?
    let CourseURL: String?
    /// Shares of lecture, group discussion, case study and practical exercises, as "60" or "".
    let Instruction_1: String?
    let Instruction_2: String?
    let Instruction_3: String?
    let Instruction_4: String?
    let Instruction_other: String?
}

nonisolated extension CourseSyllabus {
    enum CodingKeys: String, CodingKey {
        case CourseGrading, CourseObject, CourseContent, CourseTextbook, CourseRefbook, CourseNote
        case CoreAbility, CourseURL, Instruction_1, Instruction_2, Instruction_3, Instruction_4
        case Instruction_other
    }

    /// Every field as text, a number as its digits and anything else as nil, so one field of an
    /// unexpected type leaves the rest of the syllabus readable.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        func text(_ key: CodingKeys) -> String? {
            if let text = try? container.decode(String.self, forKey: key) { return text }
            if let number = try? container.decode(Int.self, forKey: key) { return String(number) }
            return (try? container.decode(Double.self, forKey: key)).map { String($0) }
        }
        self.init(
            CourseGrading: text(.CourseGrading), CourseObject: text(.CourseObject),
            CourseContent: text(.CourseContent), CourseTextbook: text(.CourseTextbook),
            CourseRefbook: text(.CourseRefbook), CourseNote: text(.CourseNote),
            CoreAbility: text(.CoreAbility), CourseURL: text(.CourseURL),
            Instruction_1: text(.Instruction_1), Instruction_2: text(.Instruction_2),
            Instruction_3: text(.Instruction_3), Instruction_4: text(.Instruction_4),
            Instruction_other: text(.Instruction_other)
        )
    }
}
