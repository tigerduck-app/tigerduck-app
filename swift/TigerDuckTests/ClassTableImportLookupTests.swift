import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClassTableImportLookupTests {
    private static let display = AppServiceBridge.CourseDisplayPreferences(
        language: "zh", courseAbbrEnabled: false, classroomAbbrEnabled: false, classroomMandarinDisplay: "original"
    )

    private static func result(_ courseNo: String, _ name: String) -> CourseSearchResult {
        CourseSearchResult(
            Semester: "1151", CourseNo: courseNo, CourseName: name, CourseTeacher: "王大明", Dimension: "",
            CreditPoint: "3", RequireOption: "R", AllYear: "H", ChooseStudent: 50, Restrict1: "0",
            Restrict2: "60", CourseTimes: "3", PracticalTimes: "0", ClassRoomNo: "TR-313", Node: "M3,M4",
            Contents: ""
        )
    }

    @Test("a code the course query does not know is left out, in the code's order otherwise")
    func unknownCourseIsSkipped() async throws {
        let courses = try await AppServiceBridge.importedCourses(
            semester: "1151", courseNos: ["MA1010001", "XX1010001", "CS1010001"], display: Self.display
        ) { courseNo in
            switch courseNo {
            case "MA1010001": [Self.result(courseNo, "微積分")]
            case "CS1010001": [Self.result(courseNo, "資料結構")]
            default: []
            }
        }

        #expect(courses.map(\.courseNo) == ["MA1010001", "CS1010001"])
        #expect(courses.map(\.courseName) == ["微積分", "資料結構"])
        #expect(courses.allSatisfy { $0.semester == "1151" })
        #expect(courses.first?.schedule == [1: ["3", "4"]])
        #expect(courses.first?.classroom == "TR-313")
    }

    @Test("one failed query fails the whole term")
    func failureThrows() async {
        await #expect(throws: URLError.self) {
            try await AppServiceBridge.importedCourses(
                semester: "1151", courseNos: ["MA1010001", "CS1010001"], display: Self.display
            ) { courseNo in
                if courseNo == "CS1010001" { throw URLError(.notConnectedToInternet) }
                return [Self.result(courseNo, "微積分")]
            }
        }
    }

    @Test("a pull on someone else's term keeps the rows the query cannot answer, and fails only when no lookup went through")
    func refreshKeepsUnansweredRows() async throws {
        let kept = SDCourse(
            courseNo: "XX1010001", courseName: "Kept", credits: 2, classroom: "", schedule: [2: ["5"]], semester: "1151"
        )
        let refreshed = try #require(await AppServiceBridge.refreshImportedCourses(
            semester: "1151", courseNos: ["MA1010001", "XX1010001", "EE1010001"], current: [kept], display: Self.display
        ) { courseNo in
            switch courseNo {
            case "MA1010001": return [Self.result(courseNo, "微積分")]
            case "XX1010001": return []
            default: throw URLError(.timedOut)
            }
        })
        #expect(refreshed.map(\.courseNo) == ["MA1010001", "XX1010001"])
        #expect(refreshed.map(\.courseName) == ["微積分", "Kept"])

        let none = await AppServiceBridge.refreshImportedCourses(
            semester: "1151", courseNos: ["MA1010001", "XX1010001"], current: [kept], display: Self.display
        ) { _ in throw URLError(.notConnectedToInternet) }
        #expect(none == nil)
    }

    @Test("a pull on someone else's term leaves the user's raw label cache alone")
    func refreshedLabelsStayOutOfOwnCache() async throws {
        let code = "QQ" + UUID().uuidString.prefix(7)
        #expect(NameAbbrService.shared.rawName(for: code) == nil)
        _ = await AppServiceBridge.refreshImportedCourses(
            semester: "1151", courseNos: [code], current: [], display: Self.display
        ) { [Self.result($0, "Refreshed label")] }

        #expect(NameAbbrService.shared.rawName(for: code) == nil)
    }

    @Test("importing another person's courses leaves the user's raw label cache alone")
    func importedLabelsStayOutOfOwnCache() async throws {
        let code = "QQ" + UUID().uuidString.prefix(7)
        #expect(NameAbbrService.shared.rawName(for: code) == nil)
        _ = try await AppServiceBridge.importedCourses(semester: "1151", courseNos: [code], display: Self.display) {
            [Self.result($0, "Imported label")]
        }

        #expect(NameAbbrService.shared.rawName(for: code) == nil)
    }
}
