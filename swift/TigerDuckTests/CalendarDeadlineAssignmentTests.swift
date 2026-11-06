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
        let semester = CourseSelectionService.currentSemesterCode()

        func timetable(_ courseNos: [String], hiding hidden: [String] = []) {
            cache.courses.saveCourses(
                courseNos.map { SDCourse(courseNo: $0, courseName: "Course \($0)", semester: semester) },
                semester: semester, for: testSignIn
            )
            cache.courses.saveDeletedCourseNos(hidden.map { CourseTombstone.key(semester: semester, courseNo: $0) }, for: testSignIn)
        }

        func deadlines(listed: [SDAssignment], shown: [SDAssignment]) {
            cache.assignments.saveAssignments(listed, for: testSignIn)
            let school = SDCalendarEvent(
                eventId: "school-survey", title: "Course survey opens", date: CalendarDeadlineAssignmentTests.due, source: .school
            )
            cache.assignments.saveCalendarEvents(shown.map(AssignmentRecords.moodleCalendarEvent) + [school], for: testSignIn)
        }

        func cacheRecords(_ ids: [Int]) {
            let records = ids.map {
                MoodleAssignmentRecord(
                    assignId: $0, cmId: $0 + 9000, courseId: 20119, name: "Lab \($0)", dueDate: CalendarDeadlineAssignmentTests.due,
                    cutoffDate: nil,
                    allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
                )
            }
            cache.moodle.saveMoodleData(
                records, fetchedAt: Date(), name: MoodleAssignmentRecord.cacheName,
                account: CalendarDeadlineAssignmentTests.account, for: testSignIn
            )
        }

        var context: MoodleCacheContext {
            MoodleCacheContext(account: CalendarDeadlineAssignmentTests.account, cache: cache.moodle, signIn: testSignIn)
        }

        func loaded(signedIn: Bool = false) -> CalendarViewModel {
            let model = CalendarViewModel(assignments: cache.assignments, courses: cache.courses)
            let context = context
            model.load { signedIn ? context : nil }
            return model
        }

        deinit { try? FileManager.default.removeItem(at: root) }
    }

    private static let account = "B11399001"
    private static let due = TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 23, minute: 59))!

    private static func assignment(_ id: String, courseNo: String, onMoodle: Bool = true) -> SDAssignment {
        SDAssignment(
            assignmentId: id, courseNo: courseNo, courseName: "Computer Networks", title: "Lab \(id)", dueDate: due,
            moodleUrl: onMoodle ? "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=9\(id)" : nil
        )
    }

    private static func opens(in model: CalendarViewModel) -> [String: String?] {
        Dictionary(
            model.events.map { ($0.eventId, model.assignment(for: $0)?.assignmentId) }, uniquingKeysWith: { first, _ in first }
        )
    }

    @Test("a Moodle deadline row resolves to the assignment Home lists; a school row, a gone assignment and a hidden course's do not")
    func deadlineRowsResolveToTheirAssignment() {
        let folder = Folder()
        folder.timetable(["CS3105301", "GE1010001"], hiding: ["GE1010001"])
        let listed = Self.assignment("5101", courseNo: "CS3105301")
        let hidden = Self.assignment("5102", courseNo: "GE1010001")
        let gone = Self.assignment("5103", courseNo: "CS3105301")
        folder.deadlines(listed: [listed, hidden], shown: [listed, hidden, gone])

        let opens = Self.opens(in: folder.loaded())

        #expect(opens["moodle-5101"] == .some("5101"))
        #expect(opens["moodle-5102"] == .some(nil))
        #expect(opens["moodle-5103"] == .some(nil))
        #expect(opens["school-survey"] == .some(nil))
    }

    @Test("a deadline opens only where its page is cached for the signed-in account or Moodle has a link for it")
    func deadlineOpensOnlyWhereSomethingCanOpen() {
        let folder = Folder()
        folder.timetable(["CS3105301"])
        let cachedOnly = Self.assignment("5201", courseNo: "CS3105301", onMoodle: false)
        let linkOnly = Self.assignment("5202", courseNo: "CS3105301")
        let neither = Self.assignment("5203", courseNo: "CS3105301", onMoodle: false)
        folder.deadlines(listed: [cachedOnly, linkOnly, neither], shown: [cachedOnly, linkOnly, neither])
        folder.cacheRecords([5201])

        let signedIn = Self.opens(in: folder.loaded(signedIn: true))
        let signedOut = Self.opens(in: folder.loaded(signedIn: false))

        #expect(signedIn["moodle-5201"] == .some("5201"))
        #expect(signedIn["moodle-5202"] == .some("5202"))
        #expect(signedIn["moodle-5203"] == .some(nil))
        #expect(signedOut["moodle-5201"] == .some(nil))
        #expect(signedOut["moodle-5202"] == .some("5202"))
    }

    @Test("hiding a course on the timetable stops its deadline opening")
    func hidingACourseStopsItsDeadlineOpening() async throws {
        let folder = Folder()
        folder.timetable(["CS3105301", "GE1010001"])
        let deadline = Self.assignment("5301", courseNo: "GE1010001")
        folder.deadlines(listed: [deadline], shown: [deadline])
        let model = folder.loaded()
        #expect(Self.opens(in: model)["moodle-5301"] == .some("5301"))

        folder.timetable(["CS3105301", "GE1010001"], hiding: ["GE1010001"])

        try await waitUntil { Self.opens(in: model)["moodle-5301"] == .some(nil) }
    }

    @Test("with an empty timetable every listed deadline opens, as Home lists every assignment then")
    func emptyTimetableListsEveryDeadline() {
        let folder = Folder()
        let first = Self.assignment("5401", courseNo: "CS3105301")
        let second = Self.assignment("5402", courseNo: "")
        folder.deadlines(listed: [first, second], shown: [first, second])

        let opens = Self.opens(in: folder.loaded())

        #expect(opens["moodle-5401"] == .some("5401"))
        #expect(opens["moodle-5402"] == .some("5402"))
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

    @Observable
    final class Navigation {
        var page: MoodleAssignmentPage?
        var signIn = testSignIn
    }

    private struct DestinationHost: View {
        let navigation: Navigation

        var body: some View {
            @Bindable var navigation = navigation
            NavigationStack {
                Text("Calendar")
                    .moodleAssignmentDestination($navigation.page, signIn: navigation.signIn, preferences: AppPreferences())
            }
        }
    }

    @Test("a pushed assignment page closes when the sign-in changes")
    func pushedPageClosesOnSignInChange() async throws {
        try await withAccessibilityAutomation {
            let root = MoodleAssignmentPageTests.folder()
            defer { try? FileManager.default.removeItem(at: root) }
            let record = MoodleAssignmentRecord(
                assignId: 701, cmId: 9701, courseId: 20119, name: "Lab 4: HTTP server", dueDate: Self.due, cutoffDate: nil,
                allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
            )
            let navigation = Navigation()
            let window = try ClubScreensTests.show(DestinationHost(navigation: navigation), look: ClubScreensTests.looks[0])
            defer { window.isHidden = true }
            try await waitUntil { ClubScreensTests.shows("Calendar", in: window) }

            navigation.page = MoodleAssignmentPage(
                entry: MoodleCourseAssignments.Entry(record: record, listed: nil),
                store: MoodleAssignmentPageTests.store(in: root), courseName: "Computer Networks"
            )
            try await waitUntil { ClubScreensTests.shows("Lab 4: HTTP server", in: window) }
            navigation.signIn = TestSignIn().signIn

            try await waitUntil { navigation.page == nil && !ClubScreensTests.shows("Lab 4: HTTP server", in: window) }
        }
    }
}
#endif
