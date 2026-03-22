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
}

// MARK: - Moodle Calendar API Response

struct MoodleCalendarWrapper: Codable {
    let error: Bool
    let data: MoodleCalendarData?
}

struct MoodleCalendarData: Codable {
    let events: [MoodleEvent]
}

struct MoodleEvent: Codable {
    let id: Int
    let name: String
    let description: String?
    let component: String?
    let modulename: String?
    let activityname: String?
    let instance: Int?
    let eventtype: String?
    let timestart: Int
    let timesort: Int
    let course: MoodleCourseInfo?
    let action: MoodleAction?
    let url: String?
}

struct MoodleCourseInfo: Codable {
    let id: Int
    let fullname: String?
    let shortname: String?
    let idnumber: String?
}

struct MoodleAction: Codable {
    let name: String?
    let url: String?
    let itemcount: Int?
    let actionable: Bool?
}

// MARK: - Moodle Calendar API Request

struct MoodleCalendarRequest: Codable {
    let index: Int
    let methodname: String
    let args: MoodleCalendarArgs

    static func upcoming(from timestamp: Int) -> MoodleCalendarRequest {
        MoodleCalendarRequest(
            index: 0,
            methodname: "core_calendar_get_action_events_by_timesort",
            args: MoodleCalendarArgs(
                limitnum: 50,
                timesortfrom: timestamp,
                limittononsuspendedevents: true
            )
        )
    }
}

struct MoodleCalendarArgs: Codable {
    let limitnum: Int
    let timesortfrom: Int
    let limittononsuspendedevents: Bool
}
