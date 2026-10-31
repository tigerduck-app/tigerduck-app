import Defaults
import Foundation
import Testing
@testable import TigerDuck

/// Each file store reads the files the app writes today, built here byte by byte in today's
/// format, from the same folders and names, and writes them back in that format.
@MainActor
@Suite(.serialized)
struct PersistenceFormatTests {
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private var cache: TestCache { TestCache(folders: CacheFolders(root: root)) }

    private func write(_ json: String, _ path: String) throws {
        let url = root.appending(path: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private func json(_ path: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(contentsOf: root.appending(path: path)))
    }

    private var language: String {
        LanguageManager.resolvedCourseApiLanguage(appLanguage: Defaults[.appLanguage])
    }

    private static let course = """
        {"courseNo":"CS1001301","courseName":"Intro","instructor":"Lin","credits":3,"classroom":"TR-313",
        "enrolledCount":50,"maxCount":60,"scheduleJSON":"{\\"1\\":[\\"3\\",\\"4\\"]}","moodleIdNumber":"1151CS1001301",
        "semester":"1151","classroomMapJSON":"{\\"1-3\\":\\"TR-313\\"}","skippedDatesJSON":"[\\"2026-09-14\\"]",
        "dimension":"A","allYear":"H","requireOption":"R"}
        """

    @Test("the course files read back a term's courses, the added, hidden and renamed ones and the drops")
    func courseFilesReadTodaysFormat() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write("[\(Self.course)]", "cache/courses_1151_\(language).json")
        try write(#"[{"courseNo":"GE1","courseName":"Mine","instructor":"","credits":2,"classroom":"","enrolledCount":0,"maxCount":0,"scheduleJSON":"{}"}]"#,
                  "persistent/user_added_courses.json")
        try write(#"["1151:EE2"]"#, "persistent/deleted_courses.json")
        try write(#"{"CS1001301":{"\#(language)":"Intro to CS"}}"#, "persistent/course_custom_names.json")
        try write(#"{"1151":["MA3"]}"#, "persistent/selection_dropped.json")
        try write(#"{"1151":["PE4"]}"#, "persistent/server_dropped.json")
        let courses = cache.courses

        let course = try #require(courses.loadCourses(semester: "1151").first)
        #expect(course.courseNo == "CS1001301" && course.instructor == "Lin" && course.credits == 3)
        #expect(course.schedule == [1: ["3", "4"]] && course.classroomMap == ["1-3": "TR-313"])
        #expect(course.skippedDates == ["2026-09-14"] && course.requireOption == "R")
        #expect(course.customName == "Intro to CS")
        let added = try #require(courses.loadUserAddedCourses().first)
        #expect(added.courseNo == "GE1" && added.moodleIdNumber == nil)
        #expect(added.semester == CourseSelectionService.currentSemesterCode())
        #expect(courses.loadDeletedCourseNos() == ["1151:EE2"])
        #expect(courses.loadSelectionDroppedNos() == ["1151": ["MA3"]])
        #expect(courses.loadServerDroppedNos(semester: "1151") == ["PE4"])

        courses.saveCourses([course], semester: "1151")
        let saved = try #require(try json("cache/courses_1151_\(language).json") as? [[String: Any]]).first
        #expect(saved?["scheduleJSON"] as? String == #"{"1":["3","4"]}"#)
        #expect(saved?["semester"] as? String == "1151" && saved?["moodleIdNumber"] as? String == "1151CS1001301")
    }

    @Test("a course name map from before names per language is read as the current language's")
    func flatCourseNamesMigrate() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"CS1001301":"Mine"}"#, "persistent/course_custom_names.json")

        #expect(cache.courses.loadCourseCustomNames() == ["CS1001301": [language: "Mine"]])
        #expect(try json("persistent/course_custom_names.json") as? [String: [String: String]] == ["CS1001301": [language: "Mine"]])
    }

    @Test("the assignment files read back the assignments, their marks and the calendar's events")
    func assignmentFilesReadTodaysFormat() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"""
            [{"assignmentId":"1","courseNo":"CS1001301","courseName":"Intro","title":"HW 1","dueDate":800000000,
            "isCompleted":false,"moodleUrl":"https://moodle2.ntust.edu.tw/mod/assign/view.php?id=9","cutoffDate":800086400,
            "submittedAt":null,"originalDueDate":null,"extensionDueDate":800172800,"semester":"1151"},
            {"assignmentId":"2","courseNo":"EE2","courseName":"Circuits","title":"Lab","dueDate":800000000,"isCompleted":true}]
            """#, "cache/assignments.json")
        try write(#"["1"]"#, "persistent/archived_assignments.json")
        try write(#"["2"]"#, "persistent/locally_completed_assignments.json")
        try write(#"["1151:EE2"]"#, "persistent/ignored_courses.json")
        try write(#"{"3":800000000}"#, "cache/closed_unsubmitted_assignments.json")
        try write(#"[{"eventId":"moodle-1","title":"HW 1","date":800000000,"sourceRaw":"moodle"}]"#, "cache/calendar_events.json")
        let store = cache.assignments

        let assignments = store.loadAssignments(semester: "1151")
        let first = try #require(assignments.first { $0.assignmentId == "1" })
        #expect(first.isArchived && first.cutoffDate == Date(timeIntervalSinceReferenceDate: 800_086_400))
        #expect(first.extensionDueDate == Date(timeIntervalSinceReferenceDate: 800_172_800))
        let second = try #require(assignments.first { $0.assignmentId == "2" })
        #expect(second.isIgnoredByCourse && second.isCompleted)
        #expect(store.loadClosedUnsubmittedAssignments() == ["3": Date(timeIntervalSinceReferenceDate: 800_000_000)])
        #expect(store.loadCalendarEvents().map(\.eventId) == ["moodle-1"])
        #expect(store.loadCalendarEvents().first?.source == .moodle)

        store.saveAssignments(assignments)
        let saved = try #require(try json("cache/assignments.json") as? [[String: Any]])
        #expect(saved.first { $0["assignmentId"] as? String == "2" }?["dueDate"] as? Double == 800_000_000)
        #expect(saved.first { $0["assignmentId"] as? String == "1" }?["semester"] as? String == "1151")
    }

    @Test("the colour file reads back the colour map and the picks")
    func colourFilesReadTodaysFormat() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"CS1001301":16711680}"#, "persistent/course_color_map.json")
        try write(#"["CS1001301"]"#, "persistent/picked_course_colors.json")

        #expect(cache.colors.loadCourseColorMapIfReadable() == ["CS1001301": 0xFF0000])
        #expect(cache.colors.loadPickedCourseColors() == ["CS1001301"])
    }

    @Test("the Moodle files read back the course id map and a course page's answer")
    func moodleFilesReadTodaysFormat() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try write(#"{"1151CS1001301":7}"#, "persistent/moodle_course_id_map.json")
        try write(#"{"fetchedAt":800000000,"value":[1,2]}"#, "cache/moodle/B11000001/forums-7.json")

        #expect(cache.moodle.lookupMoodleCourseId(idnumber: "1151CS1001301") == 7)
        let page = try #require(cache.moodle.loadMoodleData([Int].self, name: "forums-7", account: "B11000001"))
        #expect(page.value == [1, 2] && page.fetchedAt == Date(timeIntervalSinceReferenceDate: 800_000_000))
        #expect(cache.moodle.moodleFilesDir.standardizedFileURL.path == root.appending(path: "Moodle").standardizedFileURL.path)
    }

    @Test("the transcript and the bulletin list read back from their files")
    func scoreAndBulletinFilesReadTodaysFormat() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let report = try String(decoding: JSONEncoder().encode(ScoreReport.empty), as: UTF8.self)
        try write(#"{"report":\#(report),"cachedAt":1700000000}"#, "cache/score_report_B11000001.json")
        try write("[]", "cache/bulletin_summaries.json")

        let read = try #require(cache.scores.loadScoreReport(studentId: "B11000001"))
        #expect(read.report == .empty && read.cachedAt == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(cache.bulletins.loadBulletinSummaries().isEmpty)
        cache.scores.invalidateScoreReport(studentId: "B11000001")
        #expect(cache.scores.loadScoreReport(studentId: "B11000001") == nil)
    }
}
