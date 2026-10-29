import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WidgetTimelineDerivationTests {
    private func snapshot(courses: [SnapshotCourse]) -> WidgetSnapshot {
        WidgetSnapshot(
            version: 1,
            generatedAt: Date(),
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            courses: courses,
            periodTimes: [
                "A": PeriodTime(start: "08:10", end: "09:00"),
                "B": PeriodTime(start: "09:10", end: "10:00"),
                "C": PeriodTime(start: "10:20", end: "11:10"),
            ],
            periodOrder: ["A", "B", "C"],
            activeWeekdays: [1, 2, 3, 4, 5],
            activePeriodIds: ["A", "B", "C"]
        )
    }

    private func course(
        courseNo: String,
        displayName: String,
        weekday: Int,
        periods: [String],
        skippedDates: Set<String> = []
    ) -> SnapshotCourse {
        SnapshotCourse(
            courseNo: courseNo,
            displayName: displayName,
            classroom: "",
            schedule: [weekday: periods],
            colorHex: 0,
            skippedDates: skippedDates
        )
    }

    private func monday(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2024; components.month = 1; components.day = 1
        components.hour = hour; components.minute = minute
        return WidgetTaipei.calendar.date(from: components)!
    }

    private func dayKey(_ offset: Int, after date: Date) -> String {
        WidgetTimelineDerivation.dateKey(
            for: WidgetTaipei.calendar.date(byAdding: .day, value: offset, to: date)!
        )
    }

    @Test func notLoggedIn_emitsSignInState() {
        let snap = WidgetSnapshot(
            version: 1, generatedAt: Date(),
            isLoggedIn: false, accentColorHex: 0x007AFF,
            courses: [], periodTimes: [:], periodOrder: [],
            activeWeekdays: [], activePeriodIds: []
        )
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        #expect(derived == .signInRequired)
    }

    @Test func ongoing_singleCourse() {
        let courses = [course(courseNo: "A", displayName: "DS", weekday: 1, periods: ["B"])]
        let snap = snapshot(courses: courses)
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .ongoing(let list) = derived {
            #expect(list.count == 1)
            #expect(list[0].course.displayName == "DS")
            #expect(list[0].progress > 0 && list[0].progress < 1)
        } else {
            Issue.record("Expected .ongoing, got \(derived)")
        }
    }

    @Test func nextToday_betweenPeriods() {
        let earlier = course(courseNo: "A", displayName: "Early", weekday: 1, periods: ["A"])
        let later = course(courseNo: "B", displayName: "Later", weekday: 1, periods: ["C"])
        let snap = snapshot(courses: [earlier, later])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .nextToday(let info) = derived {
            #expect(info.course.displayName == "Later")
            #expect(info.day == .today)
        } else {
            Issue.record("Expected .nextToday, got \(derived)")
        }
    }

    @Test func tomorrowFirst_whenNothingLeftToday() {
        let earlier = course(courseNo: "A", displayName: "MonClass", weekday: 1, periods: ["A"])
        let tomorrow = course(courseNo: "B", displayName: "TuesClass", weekday: 2, periods: ["B"])
        let snap = snapshot(courses: [earlier, tomorrow])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(18, 0))
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "TuesClass")
            #expect(info.startTime == "09:10")
            #expect(info.day == .tomorrow)
        } else {
            Issue.record("Expected .tomorrowFirst, got \(derived)")
        }
    }

    @Test func noMoreClasses_atAll() {
        let snap = snapshot(courses: [])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        #expect(derived == .noMoreClasses)
    }

    @Test func skippedToday_removesFromOngoing() {
        let now = monday(9, 30)
        let key = WidgetTimelineDerivation.dateKey(for: now)
        let snap = snapshot(courses: [
            course(courseNo: "A", displayName: "DS", weekday: 1, periods: ["B"], skippedDates: [key]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "DS")
            #expect(info.day == .later(weekday: 1))
        } else {
            Issue.record("Expected next Monday's slot, got \(derived)")
        }
    }

    @Test func skippedToday_fallsThroughToNextNonSkipped() {
        let now = monday(9, 30)
        let key = WidgetTimelineDerivation.dateKey(for: now)
        let snap = snapshot(courses: [
            course(courseNo: "A", displayName: "Skip", weekday: 1, periods: ["C"], skippedDates: [key]),
            course(courseNo: "B", displayName: "Keep", weekday: 2, periods: ["B"]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "Keep")
        } else {
            Issue.record("Expected .tomorrowFirst with the non-skipped course, got \(derived)")
        }
    }

    @Test func nonContiguousPeriods_gapFallsThroughToNextToday() {
        let snap = snapshot(courses: [
            course(courseNo: "X", displayName: "Split", weekday: 1, periods: ["A", "C"]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .nextToday(let info) = derived {
            #expect(info.course.displayName == "Split")
            #expect(info.periodRange == "C")
        } else {
            Issue.record("Expected .nextToday during the A↔C gap, got \(derived)")
        }
    }

    @Test func contiguousPeriods_renderAsRange() {
        let snap = snapshot(courses: [
            course(courseNo: "Y", displayName: "Block", weekday: 1, periods: ["B", "C"]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .ongoing(let list) = derived {
            #expect(list.count == 1)
            #expect(list[0].periodRange == "B–C")
        } else {
            Issue.record("Expected .ongoing(B–C) during the contiguous block, got \(derived)")
        }
    }

    @Test func skippedTomorrow_advancesToDayAfter() {
        let now = monday(18, 0)
        let tomorrowKey = WidgetTimelineDerivation.dateKey(
            for: WidgetTaipei.calendar.date(byAdding: .day, value: 1, to: now)!
        )
        let snap = snapshot(courses: [
            course(courseNo: "A", displayName: "TuesSkip", weekday: 2, periods: ["B"], skippedDates: [tomorrowKey]),
            course(courseNo: "B", displayName: "WedKeep", weekday: 3, periods: ["B"]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "WedKeep")
            #expect(info.day == .later(weekday: 3))
        } else {
            Issue.record("Expected .tomorrowFirst with Wednesday's course, got \(derived)")
        }
    }

    @Test func todayRows_splitACourseIntoItsBlocks() {
        let now = monday(8, 0)
        let snap = snapshot(courses: [
            course(courseNo: "X", displayName: "Twice", weekday: 1, periods: ["C", "A"]),
            course(courseNo: "Y", displayName: "Long", weekday: 1, periods: ["A", "B"]),
            course(courseNo: "Z", displayName: "Tuesday", weekday: 2, periods: ["A"]),
        ])

        let rows = WidgetTimelineDerivation.todayRows(snapshot: snap, at: now)

        #expect(rows.map(\.id) == ["X-A", "Y-A", "X-C"])
        #expect(rows.map(\.periodRange) == ["A", "A–B", "C"])
        #expect(rows.map(\.startTime) == ["08:10", "08:10", "10:20"])
        #expect(rows.map(\.endTime) == ["09:00", "10:00", "11:10"])
    }

    @Test func todayRows_leaveOutACourseSkippedToday() {
        let now = monday(8, 0)
        let snap = snapshot(courses: [
            course(
                courseNo: "X", displayName: "Skipped", weekday: 1, periods: ["A"],
                skippedDates: [WidgetTimelineDerivation.dateKey(for: now)]
            ),
            course(courseNo: "Y", displayName: "Kept", weekday: 1, periods: ["B"]),
        ])

        #expect(WidgetTimelineDerivation.todayRows(snapshot: snap, at: now).map(\.id) == ["Y-B"])
    }

    @Test func todayRows_areEmptyOnAHoliday() {
        let now = monday(8, 0)
        var snap = snapshot(courses: [
            course(courseNo: "X", displayName: "Monday", weekday: 1, periods: ["A"]),
        ])
        snap.quietDayKeys = [WidgetTimelineDerivation.dateKey(for: now)]

        #expect(WidgetTimelineDerivation.todayRows(snapshot: snap, at: now).isEmpty)
    }

    @Test func eachBlockShowsItsOwnRoom() {
        let twoRooms = SnapshotCourse(
            courseNo: "X",
            displayName: "Twice",
            classroom: "TR-313, IB-101, EE-201",
            schedule: [1: ["A", "C"], 2: ["B"]],
            colorHex: 0,
            classroomMap: ["1-A": "TR-313", "1-C": "IB-101", "2-B": "EE-201"]
        )
        let snap = snapshot(courses: [twoRooms])

        if case .ongoing(let infos) = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(8, 30)) {
            #expect(infos.map(\.classroom) == ["TR-313"])
        } else {
            Issue.record("Expected .ongoing at 08:30")
        }
        if case .nextToday(let info) = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30)) {
            #expect(info.classroom == "IB-101")
        } else {
            Issue.record("Expected .nextToday at 09:30")
        }
        if case .tomorrowFirst(let info) = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(18, 0)) {
            #expect(info.classroom == "EE-201")
        } else {
            Issue.record("Expected .tomorrowFirst at 18:00")
        }
        let rows = WidgetTimelineDerivation.todayRows(snapshot: snap, at: monday(8, 0))
        #expect(rows.map(\.classroom) == ["TR-313", "IB-101"])
        #expect(twoRooms.classroom(weekday: 1, periods: ["A", "B", "C"]) == "TR-313, IB-101")
    }

    @Test func nextMidnight_isTaipeiMidnight() {
        let taipei = WidgetTaipei.calendar
        let lateEvening = taipei.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 23, minute: 30))!
        let midnight = taipei.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        #expect(WidgetTimelineDerivation.nextMidnight(after: lateEvening) == midnight)
        let nextDay = taipei.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        #expect(WidgetTimelineDerivation.nextMidnight(after: midnight) == nextDay)
    }

    @Test func holidayTomorrow_advancesToTheNextClassDay() {
        let now = monday(18, 0)
        let tomorrowKey = WidgetTimelineDerivation.dateKey(
            for: WidgetTaipei.calendar.date(byAdding: .day, value: 1, to: now)!
        )
        var snap = snapshot(courses: [
            course(courseNo: "A", displayName: "TuesClass", weekday: 2, periods: ["B"]),
            course(courseNo: "B", displayName: "WedClass", weekday: 3, periods: ["B"]),
        ])
        snap.quietDayKeys = [tomorrowKey]
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "WedClass")
            #expect(info.day == .later(weekday: 3))
        } else {
            Issue.record("Expected .tomorrowFirst with Wednesday's course, got \(derived)")
        }
    }

    @Test func holidayToday_offersTomorrowsFirstClass() {
        let now = monday(9, 30)
        var snap = snapshot(courses: [
            course(courseNo: "A", displayName: "MonClass", weekday: 1, periods: ["B"]),
            course(courseNo: "B", displayName: "TuesClass", weekday: 2, periods: ["B"]),
        ])
        snap.quietDayKeys = [dayKey(0, after: now)]
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "TuesClass")
            #expect(info.startTime == "09:10")
            #expect(info.day == .tomorrow)
        } else {
            Issue.record("Expected .tomorrowFirst with Tuesday's course, got \(derived)")
        }
    }

    @Test func holidayTodayAndTomorrow_offerTheNextClassDay() {
        let now = monday(9, 30)
        var snap = snapshot(courses: [
            course(courseNo: "A", displayName: "MonClass", weekday: 1, periods: ["B"]),
            course(courseNo: "B", displayName: "TuesClass", weekday: 2, periods: ["B"]),
            course(courseNo: "C", displayName: "WedClass", weekday: 3, periods: ["C"]),
        ])
        snap.quietDayKeys = [dayKey(0, after: now), dayKey(1, after: now)]
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "WedClass")
            #expect(info.startTime == "10:20")
            #expect(info.day == .later(weekday: 3))
        } else {
            Issue.record("Expected .tomorrowFirst with Wednesday's course, got \(derived)")
        }
    }

    @Test func holidayToday_withNoClassForAWeek_hasNoMoreClasses() {
        let now = monday(8, 0)
        var snap = snapshot(courses: [
            course(courseNo: "A", displayName: "MonClass", weekday: 1, periods: ["B"]),
        ])
        snap.quietDayKeys = [dayKey(0, after: now), dayKey(7, after: now)]
        #expect(WidgetTimelineDerivation.derive(snapshot: snap, at: now) == .noMoreClasses)
    }

    @Test func classDayBeforeAHoliday_keepsTodaysClasses() {
        var snap = snapshot(courses: [
            course(courseNo: "A", displayName: "MonClass", weekday: 1, periods: ["B"]),
            course(courseNo: "B", displayName: "TuesClass", weekday: 2, periods: ["B"]),
        ])
        snap.quietDayKeys = [dayKey(1, after: monday(0, 0))]

        let before = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(8, 0))
        if case .nextToday(let info) = before {
            #expect(info.course.displayName == "MonClass")
            #expect(info.day == .today)
        } else {
            Issue.record("Expected .nextToday at 08:00, got \(before)")
        }
        let during = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        if case .ongoing(let infos) = during {
            #expect(infos.map(\.course.displayName) == ["MonClass"])
        } else {
            Issue.record("Expected .ongoing at 09:30, got \(during)")
        }
    }

    @Test func holidayToday_holdsOneStateUntilMidnight() {
        let now = monday(7, 0)
        var snap = snapshot(courses: [
            course(courseNo: "A", displayName: "MonMorning", weekday: 1, periods: ["A", "B"]),
            course(courseNo: "B", displayName: "MonLate", weekday: 1, periods: ["C"]),
            course(courseNo: "C", displayName: "TuesClass", weekday: 2, periods: ["B"]),
        ])
        snap.quietDayKeys = [dayKey(0, after: now)]

        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let midnight = WidgetTimelineDerivation.nextMidnight(after: now)
        #expect(dates.first == now)
        #expect(dates.last == midnight)
        #expect(dates.count == 8)

        let states = dates.dropLast().map { WidgetTimelineDerivation.derive(snapshot: snap, at: $0) }
        #expect(states.allSatisfy { $0 == states.first })
        if case .tomorrowFirst(let info)? = states.first {
            #expect(info.course.displayName == "TuesClass")
            #expect(info.day == .tomorrow)
        } else {
            Issue.record("Expected .tomorrowFirst through the holiday, got \(String(describing: states.first))")
        }
        let atMidnight = WidgetTimelineDerivation.derive(snapshot: snap, at: midnight)
        if case .nextToday(let info) = atMidnight {
            #expect(info.course.displayName == "TuesClass")
            #expect(info.day == .today)
        } else {
            Issue.record("Expected Tuesday's class as next today at midnight, got \(atMidnight)")
        }
    }

    private func changed(
        _ periods: [String], on date: Date, cancelled: Bool = false,
        room: String? = nil, start: String? = nil, end: String? = nil
    ) -> SnapshotCourseChange {
        SnapshotCourseChange(
            day: WidgetTimelineDerivation.dateKey(for: date), periods: periods,
            cancelled: cancelled, room: room, start: start, end: end
        )
    }

    @Test func aCancelledMeetingIsNeitherOngoingNorNextButStaysInTodaysList() {
        let now = monday(8, 30)
        let gone = SnapshotCourse(
            courseNo: "A", displayName: "Gone", classroom: "R1", schedule: [1: ["A", "B"]], colorHex: 0,
            changes: [changed(["A", "B"], on: now, cancelled: true)]
        )
        let later = course(courseNo: "B", displayName: "Later", weekday: 1, periods: ["C"])
        let snap = snapshot(courses: [gone, later])

        #expect(WidgetTimelineDerivation.derive(snapshot: snap, at: now) == .nextToday(.init(
            course: later, startTime: "10:20", periodRange: "C", day: .today, classroom: ""
        )))
        #expect(WidgetTimelineDerivation.todayRows(snapshot: snap, at: now).map(\.isCancelled) == [true, false])
        let nextWeek = WidgetTaipei.calendar.date(byAdding: .day, value: 7, to: now)!
        if case .ongoing(let list) = WidgetTimelineDerivation.derive(snapshot: snap, at: nextWeek) {
            #expect(list.map(\.course.courseNo) == ["A"])
        } else {
            Issue.record("Expected next week's meeting to run")
        }
    }

    @Test func aChangedStartAndRoomReplaceTheTimetableValues() {
        let now = monday(9, 20)
        let change = changed(["B"], on: now, room: "R9", start: "09:40")
        let moved = SnapshotCourse(
            courseNo: "A", displayName: "Moved", classroom: "R1", schedule: [1: ["B"]], colorHex: 0, changes: [change]
        )
        let snap = snapshot(courses: [moved])

        #expect(WidgetTimelineDerivation.derive(snapshot: snap, at: now) == .nextToday(.init(
            course: moved, startTime: "09:40", periodRange: "B", day: .today, classroom: "R9", change: change
        )))
        if case .ongoing(let list) = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 45)) {
            #expect(list.map(\.startTime) == ["09:40"])
            #expect(list.map(\.classroom) == ["R9"])
        } else {
            Issue.record("Expected the moved meeting to run at 09:45")
        }
        #expect(WidgetTimelineDerivation.entryDates(snapshot: snap, after: monday(9, 0)).contains(monday(9, 40)))
        let rows = WidgetTimelineDerivation.todayRows(snapshot: snap, at: now)
        #expect(rows.map(\.startTime) == ["09:40"] && rows.map(\.endTime) == ["10:00"])
    }

    @Test func theNextMeetingIsTheEarliestByItsChangedStart() {
        let now = monday(8, 0)
        let split = SnapshotCourse(
            courseNo: "A", displayName: "Split", classroom: "R1", schedule: [1: ["A", "C"]], colorHex: 0,
            changes: [changed(["A"], on: now, start: "12:00", end: "12:50")]
        )
        let snap = snapshot(courses: [split])
        let sunday = WidgetTaipei.calendar.date(byAdding: .day, value: -1, to: monday(20, 0))!

        guard case .nextToday(let today) = WidgetTimelineDerivation.derive(snapshot: snap, at: now),
              case .tomorrowFirst(let tomorrow) = WidgetTimelineDerivation.derive(snapshot: snap, at: sunday) else {
            Issue.record("Expected a next meeting today and tomorrow")
            return
        }
        #expect(today.startTime == "10:20" && today.periodRange == "C")
        #expect(tomorrow.startTime == "10:20" && tomorrow.periodRange == "C")
        #expect(WidgetTimelineDerivation.todayRows(snapshot: snap, at: now).map { $0.startTime } == ["10:20", "12:00"])
    }
}
