import Foundation
import SwiftData
import Testing
@testable import TigerDuck

@MainActor
struct ScheduleSyncServiceTests {

    private static let container: ModelContainer = {
        let schema = Schema([SDCourse.self, SDAssignment.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        // swiftlint:disable:next force_try
        return try! ModelContainer(for: schema, configurations: config)
    }()

    private static func context() -> ModelContext { ModelContext(container) }

    private static func tuesdayAt(_ hour: Int, minute: Int = 0, secondsFromNow: TimeInterval = 0) -> Date {
        var comps = DateComponents()
        comps.year = 2026
        comps.month = 4
        comps.day = 21
        comps.hour = hour
        comps.minute = minute
        comps.second = 0
        return AppConstants.taipeiCalendar.date(from: comps)!.addingTimeInterval(secondsFromNow)
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
        assignmentLead: TimeInterval = 3 * 3600,
        calendar: AcademicCalendar = .empty,
        optedInHolidayIDs: Set<Int> = [],
        term: String = "1142"
    ) -> ScheduleSyncService.Inputs {
        ScheduleSyncService.Inputs(
            courses: courses,
            assignments: assignments,
            accentHex: 0x4A90E2,
            classPreparingLeadTime: classPreparingLead,
            assignmentLeadTime: assignmentLead,
            showClassPreparing: showClassPreparing,
            showInClass: showInClass,
            showAssignmentScenario: showAssignmentScenario,
            liveActivityAvailable: true,
            term: term,
            calendar: calendar,
            optedInHolidayIDs: optedInHolidayIDs
        )
    }

    private static func calendar(holidayOn day: Date, id: Int = 1) -> AcademicCalendar {
        let date = AcademicCalendar.startOfDay(day)
        return AcademicCalendar(
            revision: 1,
            terms: [],
            holidays: [
                Holiday(id: id, nameZh: "中秋節", nameEn: "Mid-Autumn Festival", start: date, end: date)
            ]
        )
    }

    @Test func emptyInputs_producesNoEvents() {
        let inputs = Self.defaultInputs(courses: [])
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)
        let events = ScheduleSyncService.buildEvents(inputs: inputs, now: now, horizonEnd: end)
        #expect(events.isEmpty)
    }

    @Test func unavailableLiveActivity_uploadsNoEvents() async {
        let ctx = Self.context()
        let course = Self.makeCourse(
            courseNo: "CS201",
            name: "Operating Systems",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        let assignment = SDAssignment(
            assignmentId: "a-201",
            courseNo: "CS201",
            courseName: "Operating Systems",
            title: "Lab 1",
            dueDate: Self.tuesdayAt(12)
        )
        ctx.insert(assignment)
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(48 * 3600)

        await NotificationSettingsFixtures.withStore { store in
            store.showClassPreparingScenario = true
            store.showInClassScenario = true
            store.showAssignmentScenario = true
            for (userSwitch, cloudSync) in [(true, true), (true, false), (false, true), (false, false)] {
                store.isLiveActivityEnabled = userSwitch
                let events = ScheduleSyncService.buildEvents(
                    inputs: ScheduleSyncService.Inputs(
                        now: now,
                        courses: { _ in [course] },
                        assignments: [assignment],
                        preferences: store,
                        cloudSyncEnabled: cloudSync,
                        accentHex: 0x4A90E2,
                        calendar: .empty,
                        optedInHolidayIDs: []
                    ),
                    now: now,
                    horizonEnd: end
                )
                if userSwitch && cloudSync {
                    #expect(!events.isEmpty)
                } else {
                    #expect(events.isEmpty, "Live Activity switch \(userSwitch), course sync \(cloudSync)")
                }
            }
        }
    }

    @Test func holiday_dropsClassEventsButKeepsAssignments() {
        let ctx = Self.context()
        let (course, assignment, now) = Self.tuesdayClassAndDeadline(context: ctx)

        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(
                courses: [course],
                assignments: [assignment],
                calendar: Self.calendar(holidayOn: Self.tuesdayAt(8))
            ),
            now: now,
            horizonEnd: now.addingTimeInterval(48 * 3600)
        )

        #expect(events.map(\.scenario) == [.assignmentUrgent])
    }

    @Test func optedInHoliday_keepsClassEvents() {
        let ctx = Self.context()
        let (course, assignment, now) = Self.tuesdayClassAndDeadline(context: ctx)

        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(
                courses: [course],
                assignments: [assignment],
                calendar: Self.calendar(holidayOn: Self.tuesdayAt(8), id: 7),
                optedInHolidayIDs: [7]
            ),
            now: now,
            horizonEnd: now.addingTimeInterval(48 * 3600)
        )

        #expect(Set(events.map(\.scenario)) == [.classPreparing, .inClass, .assignmentUrgent])
    }

    @Test func outsideTheTerm_dropsClassEventsButKeepsAssignments() {
        let ctx = Self.context()
        let (course, assignment, now) = Self.tuesdayClassAndDeadline(context: ctx)
        let tuesday = AcademicCalendar.startOfDay(Self.tuesdayAt(8))
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [
                SemesterTerm(
                    code: "1151",
                    start: AcademicCalendar.calendar.date(byAdding: .day, value: 7, to: tuesday)!,
                    end: AcademicCalendar.calendar.date(byAdding: .day, value: 120, to: tuesday)!
                ),
            ],
            holidays: []
        )

        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [course], assignments: [assignment], calendar: calendar),
            now: now,
            horizonEnd: now.addingTimeInterval(48 * 3600)
        )

        #expect(events.map(\.scenario) == [.assignmentUrgent])
    }

    @Test func theNewTermsFirstDay_getsNoneOfTheOldTermsClasses() {
        let ctx = Self.context()
        let (course, assignment, now) = Self.tuesdayClassAndDeadline(context: ctx)
        let calendar = Self.termStartingTuesday()
        let events = { (term: String) in
            ScheduleSyncService.buildEvents(
                inputs: Self.defaultInputs(courses: [course], assignments: [assignment], calendar: calendar, term: term),
                now: now,
                horizonEnd: now.addingTimeInterval(48 * 3600)
            )
        }

        #expect(events("1142").map(\.scenario) == [.assignmentUrgent])
        #expect(Set(events("1151").map(\.scenario)) == [.classPreparing, .inClass, .assignmentUrgent])
    }

    @Test func theNewTermsFirstDay_getsTheNewTermsClassesWhenCached() {
        let ctx = Self.context()
        let (old, _, now) = Self.tuesdayClassAndDeadline(context: ctx)
        let new = Self.makeCourse(courseNo: "CS302", name: "Databases", weekdayToPeriods: [2: ["6"]], context: ctx)
        var inputs = Self.defaultInputs(courses: [old], calendar: Self.termStartingTuesday())
        inputs.nextTerm = (code: "1151", courses: [new])

        let events = ScheduleSyncService.buildEvents(
            inputs: inputs, now: now, horizonEnd: now.addingTimeInterval(48 * 3600)
        )

        #expect(Set(events.map(\.scenario)) == [.classPreparing, .inClass])
        #expect(events.allSatisfy { $0.sourceId.hasPrefix("CS302_") })
    }

    @Test func theTermsAreTheGivenClocks() async {
        let ctx = Self.context()
        let (old, _, mondayEvening) = Self.tuesdayClassAndDeadline(context: ctx)
        let new = Self.makeCourse(courseNo: "CS302", name: "Databases", weekdayToPeriods: [2: ["6"]], context: ctx)

        await NotificationSettingsFixtures.withStore { store in
            let inputs = { (now: Date) in
                ScheduleSyncService.Inputs(
                    now: now,
                    courses: { $0 == "1151" ? [new] : [old] },
                    assignments: [],
                    preferences: store,
                    cloudSyncEnabled: true,
                    accentHex: 0x4A90E2,
                    calendar: Self.termStartingTuesday(),
                    optedInHolidayIDs: []
                )
            }

            let evening = inputs(mondayEvening)
            #expect(evening.term == "1142")
            #expect(evening.courses.map(\.courseNo) == ["CS301"])
            #expect(evening.nextTerm?.code == "1151")
            #expect(evening.nextTerm?.courses.map(\.courseNo) == ["CS302"])
            let weekBefore = inputs(mondayEvening.addingTimeInterval(-7 * 24 * 3600))
            #expect(weekBefore.term == "1142")
            #expect(weekBefore.nextTerm == nil)
            #expect(inputs(Self.tuesdayAt(8)).term == "1151")
        }
    }

    private static func termStartingTuesday() -> AcademicCalendar {
        let tuesday = AcademicCalendar.startOfDay(tuesdayAt(8))
        let day = { (offset: Int) in AcademicCalendar.calendar.date(byAdding: .day, value: offset, to: tuesday)! }
        return AcademicCalendar(
            revision: 1,
            terms: [
                SemesterTerm(code: "1142", start: day(-120), end: day(-1)),
                SemesterTerm(code: "1151", start: tuesday, end: day(120)),
            ],
            holidays: []
        )
    }

    @Test func withoutACalendar_theHeuristicsTermDecidesTheDay() {
        let ctx = Self.context()
        let course = Self.makeCourse(courseNo: "CS401", name: "Networks", weekdayToPeriods: [1: ["3"]], context: ctx)
        var comps = DateComponents()
        (comps.year, comps.month, comps.day, comps.hour) = (2027, 1, 31, 20)
        let sundayEvening = AppConstants.taipeiCalendar.date(from: comps)!
        let events = { (term: String) in
            ScheduleSyncService.buildEvents(
                inputs: Self.defaultInputs(courses: [course], term: term),
                now: sundayEvening,
                horizonEnd: sundayEvening.addingTimeInterval(48 * 3600)
            )
        }

        #expect(events("1151").isEmpty)
        #expect(Set(events("1152").map(\.scenario)) == [.classPreparing, .inClass])
    }

    private static func tuesdayClassAndDeadline(
        context ctx: ModelContext
    ) -> (SDCourse, SDAssignment, Date) {
        let course = makeCourse(
            courseNo: "CS301",
            name: "Compilers",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        let assignment = SDAssignment(
            assignmentId: "a-301",
            courseNo: "CS301",
            courseName: "Compilers",
            title: "Parser",
            dueDate: tuesdayAt(12)
        )
        ctx.insert(assignment)
        return (course, assignment, tuesdayAt(20, secondsFromNow: -24 * 3600))
    }

    @Test func singleCourse_emitsBothClassPreparingAndInClass() {
        let ctx = Self.context()
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
        let now = Self.tuesdayAt(8)
        let end = now.addingTimeInterval(3600)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [course]),
            now: now,
            horizonEnd: end
        )
        #expect(events.isEmpty)
    }

    @Test func assignmentWithPastLeadTime_firesImmediately() {
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
                assignmentLead: 3 * 3600
            ),
            now: now,
            horizonEnd: end
        )

        #expect(events.count == 1)
        #expect(events.first?.scenario == .assignmentUrgent)
        #expect(events.first!.fireAt > now)
        #expect(events.first!.fireAt < now.addingTimeInterval(60))
    }

    @Test func assignmentWithFutureLeadTime_isScheduled() {
        let ctx = Self.context()
        let assignment = SDAssignment(
            assignmentId: "a-1000",
            courseNo: "CS101",
            courseName: "Algorithms",
            title: "Final Project",
            dueDate: Self.tuesdayAt(20),
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
                assignmentLead: 3 * 3600
            ),
            now: now,
            horizonEnd: end
        )

        #expect(events.count == 1)
        let event = events.first
        #expect(event?.scenario == .assignmentUrgent)
        #expect(event?.snapshot.title == "Final Project")
        #expect(event?.sourceId == "a-1000")
        #expect(event?.snapshot.deepLink?.absoluteString == "tigerduck://assignment/a-1000")
    }

    @Test func classPreparingLeadTimePast_firesImmediately() {
        let ctx = Self.context()
        let course = Self.makeCourse(
            courseNo: "CS200",
            name: "Fallback-fire",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        let now = Self.tuesdayAt(10, minute: 0)
        let end = now.addingTimeInterval(48 * 3600)

        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(
                courses: [course],
                classPreparingLead: 2 * 3600
            ),
            now: now,
            horizonEnd: end
        )

        let prep = events.first { $0.scenario == .classPreparing }
        #expect(prep != nil)
        #expect(prep!.fireAt > now)
        #expect(prep!.fireAt < now.addingTimeInterval(60))
    }

    @Test func classAboutToStart_skipsClassPreparingFallback() {
        let ctx = Self.context()
        let course = Self.makeCourse(
            courseNo: "CS201",
            name: "No-head-room",
            weekdayToPeriods: [2: ["3", "4"]],
            context: ctx
        )
        let now = Self.tuesdayAt(10, minute: 19, secondsFromNow: 30)
        let end = now.addingTimeInterval(48 * 3600)

        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(
                courses: [course],
                classPreparingLead: 30 * 60
            ),
            now: now,
            horizonEnd: end
        )

        let prep = events.first { $0.scenario == .classPreparing }
        #expect(prep == nil)
        #expect(events.contains { $0.scenario == .inClass })
    }

    @Test func ignoredAndLocallyCompletedAssignments_areSkipped() {
        let ctx = Self.context()
        let assignments = [
            SDAssignment(
                assignmentId: "a-ignored", courseNo: "CS101", courseName: "Algorithms",
                title: "Ignored", dueDate: Self.tuesdayAt(20), isArchived: true
            ),
            SDAssignment(
                assignmentId: "a-marked", courseNo: "CS101", courseName: "Algorithms",
                title: "Marked done", dueDate: Self.tuesdayAt(20), isLocallyCompleted: true
            ),
            SDAssignment(
                assignmentId: "a-open", courseNo: "CS101", courseName: "Algorithms",
                title: "Open", dueDate: Self.tuesdayAt(20)
            ),
        ]
        assignments.forEach(ctx.insert)

        let now = Self.tuesdayAt(8)
        let events = ScheduleSyncService.buildEvents(
            inputs: Self.defaultInputs(courses: [], assignments: assignments),
            now: now,
            horizonEnd: now.addingTimeInterval(48 * 3600)
        )

        #expect(events.map(\.sourceId) == ["a-open"])
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
