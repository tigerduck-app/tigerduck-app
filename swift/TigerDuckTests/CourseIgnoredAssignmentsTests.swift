import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CourseIgnoredAssignmentsTests {
    private static let term = "1151"
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    private static func makeCache() -> TestCache {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CourseIgnoredAssignmentsTests-\(UUID().uuidString)", isDirectory: true)
        return TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
    }

    private static func assignment(
        _ id: String, course: String, dueIn hours: Double = 5, semester: String? = nil
    ) -> SDAssignment {
        SDAssignment(
            assignmentId: id, courseNo: course, courseName: course, title: "HW \(id)",
            dueDate: now.addingTimeInterval(hours * 3600), semester: semester
        )
    }

    private static func cacheIgnoringCS1() -> TestCache {
        let cache = makeCache()
        cache.assignments.saveAssignments([
            assignment("a1", course: "CS1"), assignment("a2", course: "CS1", dueIn: 30),
            assignment("b1", course: "EE2", dueIn: 6),
        ])
        cache.assignments.apply(.ignoreCourse(courseNo: "CS1", semester: term, ignored: true))
        return cache
    }

    private static func ids(_ assignments: [SDAssignment]) -> [String] {
        assignments.map(\.assignmentId).sorted()
    }

    @Test("Every assignment of an ignored course loads as ignored, and only that course's")
    func loadIgnoresTheCourse() {
        let loaded = Self.cacheIgnoringCS1().assignments.loadAssignments(semester: Self.term)

        #expect(Self.ids(loaded.filter(\.isIgnoredByCourse)) == ["a1", "a2"])
        #expect(Self.ids(loaded.filter(\.isArchived)) == ["a1", "a2"])
    }

    @Test("A setting from another term leaves this term's assignments alone")
    func anotherTermsSettingDoesNotApply() {
        let cache = Self.cacheIgnoringCS1()

        #expect(cache.assignments.loadAssignments(semester: "1152").filter(\.isArchived).isEmpty)
    }

    @Test("An assignment kept from last term falls under last term's setting, not this term's")
    func keptAssignmentsFollowTheTermTheyCameFrom() {
        let cache = Self.makeCache()
        cache.assignments.saveAssignments([Self.assignment("old", course: "CS1", semester: "1142")])

        cache.assignments.apply(.ignoreCourse(courseNo: "CS1", semester: Self.term, ignored: true))
        #expect(cache.assignments.loadAssignments(semester: Self.term).filter(\.isIgnoredByCourse).isEmpty)

        cache.assignments.replaceIgnoredAssignmentCourses(["1142:CS1"])
        #expect(Self.ids(cache.assignments.loadAssignments(semester: Self.term).filter(\.isIgnoredByCourse)) == ["old"])
    }

    @Test("A fetch's rows record the term they were fetched for")
    func fetchedRowsRecordTheirTerm() {
        let record = MoodleAssignmentRecord(
            assignId: 1, cmId: 1, courseId: 10, name: "HW1", dueDate: Self.now.addingTimeInterval(3600),
            cutoffDate: nil, allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
        )
        let rows = AppServiceBridge.assignments(
            from: [record],
            moodleCoursesById: [10: MoodleEnrolledCourse(id: 10, fullname: "1151CS1", shortname: "",
                                                         idnumber: "1151CS1", startDate: nil, endDate: nil)],
            courseNoByMoodleId: [10: "CS1"],
            statuses: [:],
            confirmed: [:],
            marks: AssignmentMarks(archivedIds: [], locallyCompletedIds: [], ignoredCourses: [], semester: Self.term)
        )

        #expect(rows.map(\.semester) == [Self.term])
    }

    @Test("A mark of done shows as ignored, and each assignment's own mark returns with the setting off")
    func ownMarksReturnWhenTheCourseIsNoLongerIgnored() {
        let cache = Self.cacheIgnoringCS1()
        cache.assignments.apply(.setArchived(id: "a1", true))
        cache.assignments.apply(.setCompleted(id: "a2", true))

        let ignored = cache.assignments.loadAssignments(semester: Self.term)
        #expect(Self.ids(ignored.filter(\.isArchived)) == ["a1", "a2"])
        #expect(ignored.filter(\.isLocallyCompleted).isEmpty)

        cache.assignments.apply(.ignoreCourse(courseNo: "CS1", semester: Self.term, ignored: false))
        let restored = cache.assignments.loadAssignments(semester: Self.term)
        #expect(Self.ids(restored.filter(\.isArchived)) == ["a1"])
        #expect(Self.ids(restored.filter(\.isLocallyCompleted)) == ["a2"])
        #expect(restored.filter(\.isIgnoredByCourse).isEmpty)
    }

    @Test("Home lists them under Ignored, and the badges and course details leave them out")
    func homeBadgesAndCourseDetailsFollow() {
        let loaded = Self.cacheIgnoringCS1().assignments.loadAssignments(semester: Self.term)

        #expect(Self.ids(loaded.upcomingSorted()) == ["b1"])
        #expect(Self.ids(loaded.ignoredSorted()) == ["a1", "a2"])
        #expect(!loaded.hasUnfinished(for: "CS1"))
        #expect(loaded.unfinished(for: "CS1").isEmpty)
        #expect(loaded.hasUnfinished(for: "EE2"))
    }

    @Test("The Live Activity neither starts for an ignored course's assignment nor keeps one running")
    func liveActivityFollows() {
        let loaded = Self.cacheIgnoringCS1().assignments.loadAssignments(semester: Self.term)

        let urgent = LiveActivityScenarioResolver.earliestUrgentAssignment(
            assignments: loaded, leadTime: 8 * 3600, now: Self.now
        )
        #expect(urgent?.assignmentId == "b1")
        #expect(LiveActivityScenarioResolver.isOutstanding(assignmentId: "a1", in: loaded) == false)
    }

    @Test("The 48-hour list the server starts activities from leaves them out")
    func pushScheduleFollows() {
        let loaded = Self.cacheIgnoringCS1().assignments.loadAssignments(semester: Self.term)
        let inputs = ScheduleSyncService.Inputs(
            courses: [], assignments: loaded, accentHex: 0x4A90E2,
            classPreparingLeadTime: 15 * 60, assignmentLeadTime: 3 * 3600,
            showClassPreparing: true, showInClass: true, showAssignmentScenario: true,
            liveActivityAvailable: true, term: Self.term
        )

        let events = ScheduleSyncService.buildEvents(
            inputs: inputs, now: Self.now, horizonEnd: Self.now.addingTimeInterval(48 * 3600)
        )

        #expect(events.map(\.sourceId) == ["b1"])
    }

    @Test("A fetch's rows, which Home and the class table show before the next load, are ignored too")
    func fetchedRowsFollow() {
        let record = { (id: Int, courseId: Int) in
            MoodleAssignmentRecord(
                assignId: id, cmId: id, courseId: courseId, name: "HW\(id)",
                dueDate: Self.now.addingTimeInterval(3600), cutoffDate: nil,
                allowSubmissionsFromDate: nil, intro: "", noSubmissions: false
            )
        }
        let course = { (id: Int, idnumber: String) in
            MoodleEnrolledCourse(id: id, fullname: idnumber, shortname: "", idnumber: idnumber,
                                 startDate: nil, endDate: nil)
        }

        let rows = AppServiceBridge.assignments(
            from: [record(1, 10), record(2, 20)],
            moodleCoursesById: [10: course(10, "1151CS1"), 20: course(20, "1151EE2")],
            courseNoByMoodleId: [10: "CS1", 20: "EE2"],
            statuses: [:],
            confirmed: [:],
            marks: AssignmentMarks(archivedIds: [], locallyCompletedIds: [], ignoredCourses: ["1151:CS1"],
                                   semester: Self.term)
        )

        #expect(Self.ids(rows.filter(\.isIgnoredByCourse)) == ["1"])
        #expect(Self.ids(rows.filter(\.isArchived)) == ["1"])
    }

    @Test("Sign-out clears the setting")
    func signOutClearsTheSetting() {
        let cache = Self.cacheIgnoringCS1()

        cache.forgetAccount()

        #expect(cache.assignments.loadIgnoredAssignmentCourses().isEmpty)
    }

    @Test("Deleting the course clears its setting, and a reset clears only its own term's")
    func deleteAndResetClearTheSetting() {
        let cache = Self.cacheIgnoringCS1()
        cache.assignments.apply(.ignoreCourse(courseNo: "EE2", semester: Self.term, ignored: true))
        cache.assignments.apply(.ignoreCourse(courseNo: "CS1", semester: "1142", ignored: true))

        cache.assignments.apply(.ignoreCourse(courseNo: "EE2", semester: Self.term, ignored: false))
        #expect(cache.assignments.loadIgnoredAssignmentCourses() == ["1151:CS1", "1142:CS1"])

        cache.assignments.clearIgnoredAssignmentCourses(semester: Self.term)
        #expect(cache.assignments.loadIgnoredAssignmentCourses() == ["1142:CS1"])
    }
}

@MainActor
struct ClassTableIgnoredCourseTests {
    @Test("A cell's label ends with the ignored mark, after the room")
    func voiceOverNamesTheMark() {
        let course = SDCourse(courseNo: "CS1", courseName: "Algorithms")
        let ignored = String(localized: "a11y_class_table_cell_assignments_ignored")

        #expect(spokenCourse(course, room: "TR-313", hasAssignment: false, ignoresAssignments: true)
            == "Algorithms, TR-313, \(ignored)")
        #expect(!spokenCourse(course, hasAssignment: true, ignoresAssignments: false).contains(ignored))
    }

    @Test("Only the term on show marks its ignored courses")
    func markFollowsTheTermOnShow() {
        let viewModel = ClassTableViewModel()
        viewModel.ignoredAssignmentCourses = [
            CourseTombstone.key(semester: viewModel.currentSemester, courseNo: "CS1"),
            CourseTombstone.key(semester: "1001", courseNo: "EE2"),
        ]

        #expect(viewModel.ignoresAssignments(of: "CS1"))
        #expect(!viewModel.ignoresAssignments(of: "EE2"))
    }

    @Test("Only the term assignments are fetched for offers the long-press items")
    func onlyTheAssignmentTermOffersTheItems() {
        let storedPick = Defaults[.classTableSelectedSemester]
        defer { Defaults[.classTableSelectedSemester] = storedPick }
        let viewModel = ClassTableViewModel()

        viewModel.currentSemester = CourseSelectionService.currentSemesterCode()
        #expect(viewModel.offersIgnoreAssignments)

        viewModel.currentSemester = "1001"
        #expect(!viewModel.offersIgnoreAssignments)
    }
}

@MainActor
struct HomeIgnoredCourseRowTests {
    private static let now = Date(timeIntervalSince1970: 1_790_000_000)

    @Test("A row ignored with its course offers no swipe, and one ignored on its own still does")
    func courseIgnoredRowsOfferNoSwipe() {
        let byCourse = SDAssignment(assignmentId: "a1", courseNo: "CS1", courseName: "CS1", title: "HW",
                                    dueDate: Self.now.addingTimeInterval(3600), isArchived: true)
        byCourse.isIgnoredByCourse = true
        let onItsOwn = SDAssignment(assignmentId: "b1", courseNo: "EE2", courseName: "EE2", title: "HW",
                                    dueDate: Self.now.addingTimeInterval(3600), isArchived: true)
        let view = UpcomingAssignmentsView(assignments: [byCourse, onItsOwn], filter: .ignored)

        let none = view.rowSwipeActions(for: byCourse, now: Self.now)
        #expect(none.trailing == nil)
        #expect(none.leading == nil)
        let own = view.rowSwipeActions(for: onItsOwn, now: Self.now)
        #expect(own.trailing?.label == String(localized: "assignment_ignore_undo"))
    }
}
