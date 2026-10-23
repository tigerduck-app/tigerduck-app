import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseRequireOptionTests {

    private static func searchResult(requireOption: String?, node: String = "M3,M4") -> CourseSearchResult {
        CourseSearchResult(
            Semester: "1151", CourseNo: "CS1003301", CourseName: "計算機程式設計",
            CourseTeacher: "王大明", Dimension: "", CreditPoint: "3", RequireOption: requireOption,
            AllYear: "H", ChooseStudent: 50, Restrict1: "0", Restrict2: "60", CourseTimes: "3",
            PracticalTimes: "0", ClassRoomNo: "TR-313", Node: node, Contents: ""
        )
    }

    @Test func theLookupCarriesTheFirstValueAnyRowHas() async {
        let row = await AppServiceBridge.refreshedCourseData(
            courseNo: "CS1003301",
            semester: "1151",
            cached: nil,
            moodle: nil,
            grade: nil,
            display: AppServiceBridge.CourseDisplayPreferences(
                language: "zh", courseAbbrEnabled: false, classroomAbbrEnabled: false,
                classroomMandarinDisplay: "original"
            )
        ) {
            [Self.searchResult(requireOption: nil, node: "M3"), Self.searchResult(requireOption: "R", node: "R6")]
        }
        #expect(row?.requireOption == "R")
    }

    @Test func theCourseCacheKeepsIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseRequireOptionTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = DataCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        let required = SDCourse(courseNo: "CS1003301", courseName: "計算機程式設計", semester: "1151",
                                requireOption: "R")
        let unknown = SDCourse(courseNo: "GE1001", courseName: "通識課", semester: "1151")

        cache.saveUserAddedCourses([required, unknown])

        let loaded = cache.loadUserAddedCourses()
        #expect(loaded.first { $0.courseNo == "CS1003301" }?.requireOption == "R")
        #expect(loaded.first { $0.courseNo == "GE1001" }?.requireOption == "")
    }

    @Test func onlyRIsRequired() {
        #expect(SDCourse(courseNo: "CS1003301", courseName: "計算機程式設計", requireOption: "R").isRequired)
        #expect(SDCourse(courseNo: "CS1003301", courseName: "計算機程式設計", requireOption: "r").isRequired)
        for option in ["E", "", "X"] {
            #expect(!SDCourse(courseNo: "GE1001", courseName: "通識課", requireOption: option).isRequired)
        }
    }

    @Test func theDetailRowNamesOnlyRequiredAndElective() {
        #expect(CourseDetailSheet.requireOptionText("R") == String(localized: "course_detail_require_option_required"))
        #expect(CourseDetailSheet.requireOptionText("e") == String(localized: "course_detail_require_option_elective"))
        #expect(CourseDetailSheet.requireOptionText("") == nil)
        #expect(CourseDetailSheet.requireOptionText("X") == nil)
    }

    @Test func requiredCoursesAreNotOutlinedUntilTheUserTurnsItOn() {
        #expect(!Defaults.Keys.outlineRequiredCourses.defaultValue)
    }
}
