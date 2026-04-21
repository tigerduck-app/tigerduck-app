import Foundation

// MARK: - Course Search API Response

struct CourseSearchResult: Codable {
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

// MARK: - Course Search Request

struct CourseSearchRequest: Codable {
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
    let Language: String

    static func forCourseNo(_ courseNo: String, semester: String) -> CourseSearchRequest {
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
            Language: "zh"
        )
    }

    static func forCourseName(_ name: String, semester: String) -> CourseSearchRequest {
        CourseSearchRequest(
            Semester: semester,
            CourseNo: "",
            CourseName: name,
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
            Language: "zh"
        )
    }

    static func forCourseTeacher(_ teacher: String, semester: String) -> CourseSearchRequest {
        CourseSearchRequest(
            Semester: semester,
            CourseNo: "",
            CourseName: "",
            CourseTeacher: teacher,
            Dimension: "",
            CourseNotes: "",
            CampusNotes: "",
            ForeignLanguage: 0,
            OnlyGeneral: 0,
            OnleyNTUST: 0,
            OnlyMaster: 0,
            OnlyUnderGraduate: 0,
            OnlyNode: 0,
            Language: "zh"
        )
    }
}
