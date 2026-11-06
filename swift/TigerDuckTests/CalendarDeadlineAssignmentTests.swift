import Foundation
import SwiftUI
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct CalendarDeadlineAssignmentTests {
    @MainActor
    private final class Folder {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CalendarDeadlineAssignmentTests-\(UUID().uuidString)", isDirectory: true)
        lazy var cache = TestCache(folders: CacheFolders(root: root))

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let due = TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 59))!

    private static func assignment(_ id: String, courseNo: String) -> SDAssignment {
        SDAssignment(
            assignmentId: id, courseNo: courseNo, courseName: "Computer Networks", title: "Lab \(id)", dueDate: due,
            moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=9\(id)"
        )
    }

    @Test("a Moodle deadline row resolves to the assignment Home lists; a school row, a gone assignment and a hidden course's do not")
    func deadlineRowsResolveToTheirAssignment() {
        let folder = Folder()
        let semester = CourseSelectionService.currentSemesterCode()
        let courses = folder.cache.courses
        courses.saveCourses(
            [SDCourse(courseNo: "CS3105301", courseName: "Computer Networks", semester: semester),
             SDCourse(courseNo: "GE1010001", courseName: "Art", semester: semester)],
            semester: semester, for: testSignIn
        )
        courses.saveDeletedCourseNos([CourseTombstone.key(semester: semester, courseNo: "GE1010001")], for: testSignIn)
        let listed = Self.assignment("5101", courseNo: "CS3105301")
        let hidden = Self.assignment("5102", courseNo: "GE1010001")
        let gone = Self.assignment("5103", courseNo: "CS3105301")
        folder.cache.assignments.saveAssignments([listed, hidden], for: testSignIn)
        let school = SDCalendarEvent(eventId: "school-survey", title: "Course survey opens", date: Self.due, source: .school)
        folder.cache.assignments.saveCalendarEvents(
            [listed, hidden, gone].map(AssignmentRecords.moodleCalendarEvent) + [school], for: testSignIn
        )

        let model = CalendarViewModel(assignments: folder.cache.assignments, courses: courses)
        model.load(authService: AuthService(keychainHasCredentials: { false }, notificationCenter: NotificationCenter()))
        let opens = Dictionary(
            model.events.map { ($0.eventId, model.assignment(for: $0)?.assignmentId) }, uniquingKeysWith: { first, _ in first }
        )

        #expect(opens["moodle-5101"] == .some("5101"))
        #expect(opens["moodle-5102"] == .some(nil))
        #expect(opens["moodle-5103"] == .some(nil))
        #expect(opens["school-survey"] == .some(nil))
    }
}

#if os(iOS)
@MainActor
@Suite(.serialized)
struct CalendarDayListScreenTests {
    private static let due = TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 59))!
    private static let longTitle = "Lab 4: HTTP/1.1 server with persistent connections and chunked transfer encoding"

    private static let assignment = SDAssignment(
        assignmentId: "5101", courseNo: "CS3105301", courseName: "Computer Networks", title: longTitle, dueDate: due
    )
    private static let unlisted = SDAssignment(
        assignmentId: "5102", courseNo: "GE1010001", courseName: "Art", title: "Sketch 3", dueDate: due
    )
    private static let school = SDCalendarEvent(
        eventId: "school-survey", title: "Course survey opens", date: TaipeiTime.calendar.startOfDay(for: due), source: .school
    )

    private static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    private final class Opened {
        var ids: [String] = []
    }

    private static func page(opened: Opened) -> some View {
        let events = [assignment, unlisted].map(AssignmentRecords.moodleCalendarEvent) + [school]
        return ScrollView {
            DayEventListView(
                date: due, events: events,
                assignment: { $0.eventId == "moodle-5101" ? assignment : nil },
                onOpen: { opened.ids.append($0.assignmentId) }
            )
            .padding(.vertical, TigerDuckTheme.Spacing.xxl)
        }
        .background(Color.backgroundPrimary)
    }

    @Test("only a deadline row with its assignment is a button, kept in the page, and opens that assignment",
          arguments: ClubScreensTests.looks)
    func deadlineRowOpensItsAssignment(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let opened = Opened()
            let window = try ClubScreensTests.show(
                Self.page(opened: opened), look: look, height: look.textSize == .large ? 812 : 2000
            )
            defer { window.isHidden = true }
            let row = { @MainActor in
                exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.contains(Self.longTitle) == true }
            }
            try await waitUntil { row() != nil }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "calendar-day-list-\(look.testDescription)-\(Self.language)")

            let deadline = try #require(row())
            #expect(deadline.accessibilityTraits.contains(.button))
            #expect(deadline.accessibilityFrame.minX >= 0 && deadline.accessibilityFrame.maxX <= window.bounds.maxX + 0.5)
            for title in ["Sketch 3", "Course survey opens"] {
                let other = try #require(
                    exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.contains(title) == true }, "\(title)"
                )
                #expect(!other.accessibilityTraits.contains(.button), "\(title)")
            }

            _ = deadline.accessibilityActivate()
            #expect(opened.ids == ["5101"])
        }
    }
}
#endif
