import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

enum LiveActivityScenarioCases {
    static func tuesday(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        TaipeiTime.calendar.date(from: DateComponents(
            year: 2026, month: 9, day: 22, hour: hour, minute: minute, second: second
        ))!
    }

    static let tuesdayPeriods: [String: [String]] = [
        "CS101": ["3", "4"],
        "CS102": ["6", "7"],
        "CS103": ["4"],
    ]

    struct Due: Sendable {
        var id = "a1"
        var dueIn: TimeInterval
        var isCompleted = false
        var isArchived = false
        var isLocallyCompleted = false
    }

    enum HolidayToday: Sendable {
        case none
        case quiet
        case optedIn
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let testDescription: String
        var now: Date
        var courseNos = ["CS101", "CS102"]
        var skipped: Set<String> = []
        var dues: [Due] = []
        var holiday = HolidayToday.none
        var inTerm = true
        var liveActivityOn = true
        var showAssignment = true
        var showInClass = true
        var showPreparing = true
        var classLead: TimeInterval = 3600
        var assignmentLead: TimeInterval = 8 * 3600
        var expected: LiveActivityScenarioKind?
        var expectedSourceId: String?
    }

    static let firstClass = "CS101_20260922_3"
    static let secondClass = "CS102_20260922_6"

    static let cases: [Case] = [
        Case(
            testDescription: "a deadline due soon wins over the class in progress",
            now: tuesday(11), dues: [Due(dueIn: 3600)],
            expected: .assignmentUrgent, expectedSourceId: "a1"
        ),
        Case(
            testDescription: "with the assignment scenario off the class in progress shows",
            now: tuesday(11), dues: [Due(dueIn: 3600)], showAssignment: false,
            expected: .inClass, expectedSourceId: firstClass
        ),
        Case(
            testDescription: "the class in progress wins over the class about to start",
            now: tuesday(11), classLead: 4 * 3600,
            expected: .inClass, expectedSourceId: firstClass
        ),
        Case(
            testDescription: "with the in-class scenario off the class about to start shows",
            now: tuesday(11), showInClass: false, classLead: 4 * 3600,
            expected: .classPreparing, expectedSourceId: secondClass
        ),
        Case(
            testDescription: "the next class within its lead time",
            now: tuesday(12, 30),
            expected: .classPreparing, expectedSourceId: secondClass
        ),
        Case(
            testDescription: "with the preparing scenario off nothing shows before class",
            now: tuesday(12, 30), showPreparing: false
        ),
        Case(
            testDescription: "a class starting one lead time away",
            now: tuesday(12, 20),
            expected: .classPreparing, expectedSourceId: secondClass
        ),
        Case(
            testDescription: "a class starting one second past the lead time",
            now: tuesday(12, 19, 59)
        ),
        Case(
            testDescription: "a class whose end is now has ended",
            now: tuesday(12, 10)
        ),
        Case(
            testDescription: "nothing after the last class",
            now: tuesday(16)
        ),
        Case(
            testDescription: "a deadline one lead time away",
            now: tuesday(8), dues: [Due(dueIn: 8 * 3600)],
            expected: .assignmentUrgent, expectedSourceId: "a1"
        ),
        Case(
            testDescription: "a deadline one second past the lead time",
            now: tuesday(8), dues: [Due(dueIn: 8 * 3600 + 1)]
        ),
        Case(
            testDescription: "a deadline that is now has passed",
            now: tuesday(8), dues: [Due(dueIn: 0)]
        ),
        Case(
            testDescription: "a submitted assignment",
            now: tuesday(8), dues: [Due(dueIn: 3600, isCompleted: true)]
        ),
        Case(
            testDescription: "an ignored assignment",
            now: tuesday(8), dues: [Due(dueIn: 3600, isArchived: true)]
        ),
        Case(
            testDescription: "an assignment marked done",
            now: tuesday(8), dues: [Due(dueIn: 3600, isLocallyCompleted: true)]
        ),
        Case(
            testDescription: "the deadline after an ignored one",
            now: tuesday(8),
            dues: [Due(id: "a1", dueIn: 3600, isArchived: true), Due(id: "a2", dueIn: 2 * 3600)],
            expected: .assignmentUrgent, expectedSourceId: "a2"
        ),
        Case(
            testDescription: "the earliest of several deadlines",
            now: tuesday(8), dues: [Due(id: "a2", dueIn: 3 * 3600), Due(id: "a1", dueIn: 3600)],
            expected: .assignmentUrgent, expectedSourceId: "a1"
        ),
        Case(
            testDescription: "a holiday silences the class in progress",
            now: tuesday(11), holiday: .quiet
        ),
        Case(
            testDescription: "a holiday silences the class about to start",
            now: tuesday(12, 30), holiday: .quiet
        ),
        Case(
            testDescription: "a deadline on a holiday still shows",
            now: tuesday(11), dues: [Due(dueIn: 3600)], holiday: .quiet,
            expected: .assignmentUrgent, expectedSourceId: "a1"
        ),
        Case(
            testDescription: "a holiday the user still has class on",
            now: tuesday(11), holiday: .optedIn,
            expected: .inClass, expectedSourceId: firstClass
        ),
        Case(
            testDescription: "outside the term no class is in progress",
            now: tuesday(11), inTerm: false
        ),
        Case(
            testDescription: "outside the term no class is about to start",
            now: tuesday(12, 30), inTerm: false
        ),
        Case(
            testDescription: "a deadline outside the term still shows",
            now: tuesday(11), dues: [Due(dueIn: 3600)], inTerm: false,
            expected: .assignmentUrgent, expectedSourceId: "a1"
        ),
        Case(
            testDescription: "a skipped class in progress does not show",
            now: tuesday(11), skipped: ["CS101"]
        ),
        Case(
            testDescription: "the class after a skipped one",
            now: tuesday(11), skipped: ["CS101"], classLead: 4 * 3600,
            expected: .classPreparing, expectedSourceId: secondClass
        ),
        Case(
            testDescription: "a skipped next class does not show",
            now: tuesday(12, 30), skipped: ["CS102"]
        ),
        Case(
            testDescription: "of two overlapping classes the earlier start shows",
            now: tuesday(11, 30), courseNos: ["CS103", "CS101"],
            expected: .inClass, expectedSourceId: firstClass
        ),
        Case(
            testDescription: "nothing while Live Activity is switched off",
            now: tuesday(11), dues: [Due(dueIn: 3600)], liveActivityOn: false
        ),
    ]
}

@MainActor
struct LiveActivityScenarioResolverTests {

    private static func courses(_ courseNos: [String], skipped: Set<String>) -> [SDCourse] {
        courseNos.map { courseNo in
            let course = SDCourse(
                courseNo: courseNo,
                courseName: courseNo,
                classroom: "TR-313",
                schedule: [2: LiveActivityScenarioCases.tuesdayPeriods[courseNo] ?? []]
            )
            if skipped.contains(courseNo) {
                course.skippedDates = ["2026-09-22"]
            }
            return course
        }
    }

    private static func assignment(_ due: LiveActivityScenarioCases.Due, now: Date) -> SDAssignment {
        SDAssignment(
            assignmentId: due.id,
            courseNo: "CS101",
            courseName: "CS101",
            title: "Homework \(due.id)",
            dueDate: now.addingTimeInterval(due.dueIn),
            isCompleted: due.isCompleted,
            isArchived: due.isArchived,
            isLocallyCompleted: due.isLocallyCompleted
        )
    }

    private static func calendar(for c: LiveActivityScenarioCases.Case) -> AcademicCalendar {
        let day = AcademicCalendar.startOfDay(c.now)
        let holidays = c.holiday == .none
            ? []
            : [Holiday(id: 1, nameZh: "國慶日", nameEn: "National Day", start: day, end: day)]
        let terms = c.inTerm ? [] : [
            SemesterTerm(
                code: "1151",
                start: AcademicCalendar.calendar.date(byAdding: .day, value: 7, to: day)!,
                end: AcademicCalendar.calendar.date(byAdding: .day, value: 120, to: day)!
            ),
        ]
        return AcademicCalendar(revision: 1, terms: terms, holidays: holidays)
    }

    private static func resolve(
        _ c: LiveActivityScenarioCases.Case,
        store: LiveActivityPreferencesStore
    ) -> LiveActivitySnapshot? {
        store.isLiveActivityEnabled = c.liveActivityOn
        store.showAssignmentScenario = c.showAssignment
        store.showInClassScenario = c.showInClass
        store.showClassPreparingScenario = c.showPreparing
        store.classPreparingLeadTime = c.classLead
        store.assignmentLiveActivityLeadTime = c.assignmentLead
        return LiveActivityScenarioResolver().resolve(
            courses: courses(c.courseNos, skipped: c.skipped),
            assignments: c.dues.map { assignment($0, now: c.now) },
            preferences: store,
            cloudSyncEnabled: true,
            accentHex: 0x007AFF,
            now: c.now,
            calendar: calendar(for: c),
            optedInHolidayIDs: c.holiday == .optedIn ? [1] : []
        )
    }

    @Test(arguments: LiveActivityScenarioCases.cases)
    func picksTheScenario(_ c: LiveActivityScenarioCases.Case) async {
        await NotificationSettingsFixtures.withStore { store in
            let snapshot = Self.resolve(c, store: store)
            #expect(snapshot?.scenario == c.expected)
            #expect(snapshot?.sourceId == c.expectedSourceId)
        }
    }

    @Test func inClassCoversTheBlockInProgress() throws {
        let course = SDCourse(
            courseNo: "CS200",
            courseName: "Compilers",
            classroom: "TR-313, IB-101",
            schedule: [2: ["3", "4", "7", "8"]],
            classroomMap: ["2-3": "TR-313", "2-4": "TR-313", "2-7": "IB-101", "2-8": "IB-101"]
        )
        let now = LiveActivityScenarioCases.tuesday(15)
        let timeline = CourseTimelineResolver().timeline(for: [course], around: now)
        guard case .inClass(let slots) = CourseTimelineResolver().nonSkippedState(at: now, in: timeline) else {
            Issue.record("expected the 7-8 block to be in progress")
            return
        }
        let slot = try #require(slots.first)

        let snapshot = LiveActivityScenarioResolver.inClassSnapshot(slot: slot, now: now, accentHex: 0)

        #expect(snapshot.scenario == .inClass)
        #expect(snapshot.title == "Compilers")
        let start = LiveActivityScenarioCases.tuesday(14, 20)
        let end = LiveActivityScenarioCases.tuesday(16, 20)
        #expect(snapshot.subtitle == "\(start.timeString) - \(end.timeString)")
        #expect(snapshot.progressStart == start)
        #expect(snapshot.countdownTarget == end)
        #expect(snapshot.sourceId == "CS200_20260922_7")
        #expect(slot.periods == ["7", "8"])
        #expect(snapshot.locationText == "IB-101")
    }

    @Test func classPreparingCountsDownToTheStart() throws {
        let course = SDCourse(courseNo: "CS201", courseName: "Networks", schedule: [2: ["6", "7"]])
        let now = LiveActivityScenarioCases.tuesday(12, 30)
        let timeline = CourseTimelineResolver().timeline(for: [course], around: now)
        let slot = try #require(LiveActivityScenarioResolver.nextNonSkippedSlot(in: timeline, after: now))

        let snapshot = LiveActivityScenarioResolver.classPreparingSnapshot(slot: slot, accentHex: 0)

        #expect(snapshot.scenario == .classPreparing)
        let start = LiveActivityScenarioCases.tuesday(13, 20)
        let end = LiveActivityScenarioCases.tuesday(15, 10)
        #expect(snapshot.subtitle == "\(start.timeString) - \(end.timeString)")
        #expect(snapshot.countdownTarget == start)
        #expect(snapshot.progressStart == nil)
        #expect(snapshot.sourceId == "CS201_20260922_6")
    }

    @Test func assignmentProgressSpansTheLeadTime() {
        let due = LiveActivityScenarioCases.tuesday(23, 59)
        let assignment = SDAssignment(
            assignmentId: "42",
            courseNo: "CS101",
            courseName: "Algorithms",
            title: "Lab 3",
            dueDate: due
        )
        let course = SDCourse(courseNo: "CS101", courseName: "Algorithms", instructor: "Lin")

        let snapshot = LiveActivityScenarioResolver.assignmentSnapshot(
            assignment: assignment,
            courses: [course],
            leadTime: 8 * 3600,
            accentHex: 0
        )

        #expect(snapshot.scenario == .assignmentUrgent)
        #expect(snapshot.title == "Lab 3")
        #expect(snapshot.subtitle == "Algorithms")
        #expect(snapshot.instructor == "Lin")
        #expect(snapshot.countdownTarget == due)
        #expect(snapshot.progressStart == due.addingTimeInterval(-8 * 3600))
        #expect(snapshot.sourceId == "42")
    }

    @Test func assignmentTapOpensTigerDuck() {
        let assignment = SDAssignment(
            assignmentId: "42",
            courseNo: "CS101",
            courseName: "Algorithms",
            title: "Lab 3",
            dueDate: LiveActivityScenarioCases.tuesday(23, 59),
            moodleUrl: "https://moodle2.ntust.edu.tw/mod/assign/view.php?id=5501"
        )

        let snapshot = LiveActivityScenarioResolver.assignmentSnapshot(
            assignment: assignment,
            leadTime: 8 * 3600,
            accentHex: 0
        )

        #expect(snapshot.deepLink?.absoluteString == "tigerduck://assignment/42")
    }
}
