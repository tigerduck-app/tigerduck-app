import Foundation
import Testing
@testable import TigerDuck

/// A course fetch applies what it found to the courses as they are when it ends, so an edit, a
/// newer roster or a display change that lands while its lookups run is kept.
@MainActor
struct CourseFetchRaceTests {
    private static let semester = "1151"
    private static let zh = AppServiceBridge.CourseDisplayPreferences(
        language: "zh", courseAbbrEnabled: false, classroomAbbrEnabled: false, classroomMandarinDisplay: "original"
    )

    private final class DisplayBox {
        var value = CourseFetchRaceTests.zh
    }

    private let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    private let display = DisplayBox()

    private var store: CourseStore {
        CourseStore(folders: CacheFolders(root: root)) { [display] in display.value }
    }

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

    @Test("a course added or removed while the added courses refresh stays added or removed")
    func anEditDuringTheAddedCourseRefreshIsKept() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store
        store.saveUserAddedCourses([Self.course("AA1"), Self.course("BB2")])

        let kept = await AppServiceBridge.refreshUserAddedCourses(
            semester: Self.semester, authService: Self.auth(), courses: store
        ) { _, courseNo, _, _ in
            store.apply(.remove(courseNo: "BB2", semester: Self.semester))
            store.apply(.add(Self.course("CC3"), semester: Self.semester))
            return [Self.result(courseNo, name: "New")]
        }

        let saved = store.loadUserAddedCourses()
        #expect(saved.map(\.courseNo) == ["AA1", "CC3"])
        #expect(saved.map(\.courseName) == ["New", "Old"])
        #expect(kept.map(\.courseNo) == ["AA1", "CC3"])
    }

    @Test("a roster saved while the classroom refresh runs keeps its courses")
    func aNewerRosterDuringTheClassroomRefreshIsKept() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store
        store.saveCourses([Self.course("EN1"), Self.course("EN2")], semester: Self.semester)
        store.saveUserAddedCourses([Self.course("UA1"), Self.course("UA2")])

        let applied = await AppServiceBridge.refreshCoursesMissingClassroom(
            semester: Self.semester, authService: Self.auth(), courses: store
        ) { _, courseNo, _, _ in
            store.saveCourses([Self.course("EN1"), Self.course("EN3")], semester: Self.semester)
            store.apply(.remove(courseNo: "UA2", semester: Self.semester))
            return [Self.result(courseNo, name: "New")]
        }

        let enrolled = store.loadCourses(semester: Self.semester)
        #expect(applied)
        #expect(enrolled.map(\.courseNo) == ["EN1", "EN3"])
        #expect(enrolled.map(\.classroom) == ["TR-313", ""])
        #expect(store.loadUserAddedCourses().map(\.courseNo) == ["UA1"])
        #expect(store.loadUserAddedCourses().first?.classroom == "TR-313")
    }

    @Test("names looked up before a language change are not saved")
    func namesFromBeforeALanguageChangeAreDropped() async {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store
        store.saveUserAddedCourses([Self.course("AA1")])

        let kept = await AppServiceBridge.refreshUserAddedCourses(
            semester: Self.semester, authService: Self.auth(), courses: store
        ) { [display] _, courseNo, _, _ in
            display.value = AppServiceBridge.CourseDisplayPreferences(
                language: "en", courseAbbrEnabled: false, classroomAbbrEnabled: false,
                classroomMandarinDisplay: "original"
            )
            return [Self.result(courseNo, name: "New")]
        }

        #expect(store.loadUserAddedCourses().map(\.courseName) == ["Old"])
        #expect(kept.map(\.courseName) == ["Old"])
        #expect(!store.saveFetchedCourses(
            [Self.course("EN1", name: "New")], semester: Self.semester, display: Self.zh, since: store.editToken
        ))
        #expect(store.loadCourses(semester: Self.semester).isEmpty)
    }

    @Test("a course another device added stays when the class table removes one of the user's")
    func anotherDevicesAddSurvivesAClassTableEdit() {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = store
        let viewModel = ClassTableViewModel(courses: store, importedTables: ImportedClassTableStore(
            fileURL: root.appendingPathComponent("imported_class_tables.json"), signedInStudentId: { "B11300000" }
        ))
        let term = viewModel.currentSemester
        let mine = SDCourse(courseNo: "GE1010001", courseName: "Art", semester: term)
        store.saveUserAddedCourses([mine])
        viewModel.courses = [mine]

        store.saveUserAddedCourses([mine, SDCourse(courseNo: "GE1010002", courseName: "Music", semester: term)])
        viewModel.removeUserAddedCourse(courseNo: "GE1010001")

        #expect(store.loadUserAddedCourses().map(\.courseNo) == ["GE1010002"])
    }
}
