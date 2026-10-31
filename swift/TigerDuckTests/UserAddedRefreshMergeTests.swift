import Foundation
import Testing
@testable import TigerDuck

@Suite(.serialized)
@MainActor
struct UserAddedRefreshMergeTests {
    private static let semester = "1151"

    private static func result(_ courseNo: String, name: String) -> CourseSearchResult {
        CourseSearchResult(
            Semester: semester, CourseNo: courseNo, CourseName: name, CourseTeacher: "T", Dimension: "",
            CreditPoint: "3", RequireOption: "R", AllYear: "H", ChooseStudent: 50, Restrict1: "0",
            Restrict2: "60", CourseTimes: "3", PracticalTimes: "0", ClassRoomNo: "TR-313", Node: "M3,M4",
            Contents: ""
        )
    }

    private static func course(_ courseNo: String, name: String = "Old") -> SDCourse {
        SDCourse(courseNo: courseNo, courseName: name, classroom: "", semester: semester)
    }

    private static func auth() -> AuthService {
        AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter())
    }

    private func isolated(_ body: () async -> Void) async {
        let userAdded = DataCache.shared.loadUserAddedCourses()
        let enrolled = DataCache.shared.loadCourses(semester: Self.semester)
        defer {
            DataCache.shared.saveUserAddedCourses(userAdded)
            DataCache.shared.saveCourses(enrolled, semester: Self.semester)
        }
        await body()
    }

    @Test("a course added during the lookups stays, a deleted one stays deleted, the rest get the details")
    func userAddedRefreshAppliesToCurrentList() async {
        await isolated {
            DataCache.shared.saveUserAddedCourses([Self.course("AA1"), Self.course("BB2")])
            let kept = await AppServiceBridge.refreshUserAddedCourses(
                semester: Self.semester, authService: Self.auth()
            ) { _, courseNo, _, _ in
                DataCache.shared.saveUserAddedCourses([Self.course("AA1"), Self.course("CC3")])
                return [Self.result(courseNo, name: "New")]
            }

            let saved = DataCache.shared.loadUserAddedCourses()
            #expect(saved.map(\.courseNo) == ["AA1", "CC3"])
            #expect(saved.first { $0.courseNo == "AA1" }?.courseName == "New")
            #expect(kept.map(\.courseNo) == ["AA1", "CC3"])
        }
    }

    @Test("a roster change and a user-added delete made during the classroom lookups are kept")
    func classroomRefreshAppliesToCurrentLists() async {
        await isolated {
            DataCache.shared.saveCourses([Self.course("EN1"), Self.course("EN2")], semester: Self.semester)
            DataCache.shared.saveUserAddedCourses([Self.course("UA1"), Self.course("UA2")])
            let didFind = await AppServiceBridge.refreshCoursesMissingClassroom(
                semester: Self.semester, authService: Self.auth()
            ) { _, courseNo, _, _ in
                DataCache.shared.saveCourses([Self.course("EN1"), Self.course("EN3")], semester: Self.semester)
                DataCache.shared.saveUserAddedCourses([Self.course("UA1")])
                return [Self.result(courseNo, name: "New")]
            }

            let enrolled = DataCache.shared.loadCourses(semester: Self.semester)
            #expect(didFind)
            #expect(enrolled.map(\.courseNo) == ["EN1", "EN3"])
            #expect(enrolled.first { $0.courseNo == "EN1" }?.classroom == "TR-313")
            #expect(DataCache.shared.loadUserAddedCourses().map(\.courseNo) == ["UA1"])
            #expect(DataCache.shared.loadUserAddedCourses().first?.classroom == "TR-313")
        }
    }
}
