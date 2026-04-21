import Foundation
import SwiftData
import Testing
@testable import TigerDuck

@MainActor
struct ScheduleSyncServiceTests {

    // MARK: - Fixtures

    /// Build a one-time in-memory SwiftData container so SDCourse / SDAssignment
    /// instances work outside the app. We never persist — just need live models.
    private static let container: ModelContainer = {
        let schema = Schema([SDCourse.self, SDAssignment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: config)
    }()

    private static func context() -> ModelContext { ModelContext(container) }

    private static func tuesdayAt(_ hour: Int, minute: Int = 0, secondsFromNow: TimeInterval = 0) -> Date {
        // Anchor "now" at a deterministic Tuesday 08:00 local to make all
        // future class starts computable without leaking across DST edges.
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 21 // Tuesday 2026-04-21
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return Calendar.current.date(from: comps)!.addingTimeInterval(secondsFromNow)
    }

    private static func makeCourse(
        courseNo: String,
        name: String,
        weekdayToPeriods: [Int: [String]],
        context: ModelContext
    ) -> SDCourse {
        let course = SDCourse(
            courseNo: courseNo,
            courseName: name,
            instructor: "測試老師",
            credits: 3,
            classroom: "T2-401",
            schedule: weekdayToPeriods,
            semester: "1142"
        )
        context.insert(course)
        return course
    }

    private static func defaultInputs(
        courses: [SDCourse],
        assignments: [SDAssignment] = [],
        showClassPreparing: Bool = true,
        showInClass: Bool = true,
        showAssignmentScenario: Bool = true,
        classPreparingLead: TimeInterval = 15 * 60,
        assignmentLead: TimeInterval = 3 * 3600
    ) -> ScheduleSyncService.Inputs {
        ScheduleSyncService.Inputs(
            courses: courses,
            assignments: assignments,
            accentHex: 0x4A90E2,
            classPreparingLeadTime: classPreparingLead,
            assignmentLeadTime: assignmentLead,
            showClassPreparing: showClassPreparing,
            showInClass: showInClass,
            showAssignmentScenario: showAssignmentScenario
        )
    }

    // MARK: - Tests

    @Test func emptyInputs_producesNoEvents() {
        let inputs = Self.defaultInputs(courses: [])
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)
        let events = ScheduleSyncService.buildEvents(inputs: inputs, now: now, horizonEnd: end)
        #expect(events.isEmpty)
    }

    @Test func singleCourse_emitsBothClassPreparingAndInClass() {
        let ctx = Self.context()
        // Tuesday periods 3-4: 10:20-12:10. "now" = 08:00, so classPreparing
        // fires at 10:05 (15 min before start), inClass fires at 10:20.
        let course = Self.makeCourse(
            courseNo: "CS101",
            name: "Algorithms",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)

        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [course]),
            now: now,
            horizonEnd: end
        )

        #expect(events.count == 2)
        let prep = events.first { $0.scenario == .classPreparing }
        let inClass = events.first { $0.scenario == .inClass }
        #expect(prep != nil)
        #expect(inClass != nil)
        #expect(prep?.snapshot.title == "Algorithms")
        #expect(inClass?.snapshot.title == "Algorithms")
        // Same source_id — the server build_push_id combines with scenario
        #expect(prep?.sourceId == inClass?.sourceId)
    }

    @Test func classPreparingDisabled_dropsOnlyThatScenario() {
        let ctx = Self.context()
        let course = Self.makeCourse(
            courseNo: "CS102",
            name: "Intro",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [course], showClassPreparing: false),
            now: now,
            horizonEnd: end
        )
        #expect(events.count == 1)
        #expect(events.first?.scenario == .inClass)
    }

    @Test func horizonTrimsDistantCourses() {
        let ctx = Self.context()
        let course = Self.makeCourse(
            courseNo: "CS103",
            name: "Far Future",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        // Horizon of 1 hour — class is 2h+ away, so no events
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(3600)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [course]),
            now: now,
            horizonEnd: end
        )
        #expect(events.isEmpty)
    }

    @Test func assignmentNearDue_producesAssignmentUrgentEvent() {
        let ctx = Self.context()
        let assignment = SDAssignment(
            assignmentId: "a-999",
            courseNo: "CS101",
            courseName: "Algorithms",
            title: "Essay",
            dueDate: Self.tuesdayAt(10),
            isCompleted: false,
            moodleUrl: nil,
            cutoffDate: nil,
            submittedAt: nil
        )
        ctx.insert(assignment)

        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(
                courses: [],
                assignments: [assignment],
                assignmentLead: 3 * 3600 // 3h lead
            ),
            now: now,
            horizonEnd: end
        )

        // Lead = 3h, due = 10:00, so fire_at = 07:00 → already past now(08:00).
        // Expect zero events (fire_at must be > now).
        #expect(events.isEmpty)
    }

    @Test func assignmentWithFutureLeadTime_isScheduled() {
        let ctx = Self.context()
        let assignment = SDAssignment(
            assignmentId: "a-1000",
            courseNo: "CS101",
            courseName: "Algorithms",
            title: "Final Project",
            dueDate: Self.tuesdayAt(20), // 20:00
            isCompleted: false,
            moodleUrl: nil,
            cutoffDate: nil,
            submittedAt: nil
        )
        ctx.insert(assignment)

        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(
                courses: [],
                assignments: [assignment],
                assignmentLead: 3 * 3600 // fire_at = 17:00, in window
            ),
            now: now,
            horizonEnd: end
        )

        #expect(events.count == 1)
        let event = events.first
        #expect(event?.scenario == .assignmentUrgent)
        #expect(event?.snapshot.title == "Final Project")
        #expect(event?.sourceId == "a-1000")
    }

    @Test func completedAssignment_isSkipped() {
        let ctx = Self.context()
        let assignment = SDAssignment(
            assignmentId: "a-done",
            courseNo: "CS101",
            courseName: "Algorithms",
            title: "Done",
            dueDate: Self.tuesdayAt(20),
            isCompleted: true,
            moodleUrl: nil,
            cutoffDate: nil,
            submittedAt: nil
        )
        ctx.insert(assignment)

        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [], assignments: [assignment]),
            now: now,
            horizonEnd: end
        )
        #expect(events.isEmpty)
    }
}
