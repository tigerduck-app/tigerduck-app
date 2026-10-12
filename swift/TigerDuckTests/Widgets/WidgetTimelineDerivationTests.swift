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

    /// Pick a fixed Monday for deterministic tests (2024-01-01 was a Monday).
    private func monday(_ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = 2024; components.month = 1; components.day = 1
        components.hour = hour; components.minute = minute
        return Calendar(identifier: .gregorian).date(from: components)!
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
        // 09:30 — Earlier ended at 09:00; Later starts at 10:20.
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
        // 18:00 Monday — nothing left today
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(18, 0))
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "TuesClass")
            #expect(info.startTime == "09:10")
            // Monday 18:00 → Tuesday really is tomorrow.
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

    /// Marking today's in-progress class as skipped must drop it out of
    /// `.ongoing` so the widget stops showing the cancelled class as the
    /// active slot.
    ///
    /// It does not fall through to `.noMoreClasses`: the course still meets
    /// next Monday, and the seven-day scan finds it so a one-class-a-week
    /// timetable does not read as empty for six days. The scan must not
    /// caption that slot "Tomorrow", hence the `day` assertion.
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

    /// When today's *upcoming* class is skipped but a later non-skipped class
    /// exists, derivation should skip past the cancelled slot to the next real one.
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

    /// A course scheduled at A (08:10–09:00) and C (10:20–11:10) — with B
    /// unscheduled — must NOT report as ongoing during the 09:00–10:20 gap.
    /// The gap should fall through to `.nextToday(C)`.
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

    /// Adjacent-in-`order` periods (B and C) should still render as one block
    /// "B–C" while inside that block's envelope — the gap fix must not break
    /// the contiguous-run span behavior.
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

    /// `tomorrowFirst` advances per-day, so the skip check must use each target
    /// date's key — not today's — when scanning ahead.
    @Test func skippedTomorrow_advancesToDayAfter() {
        let now = monday(18, 0)
        let tomorrowKey = WidgetTimelineDerivation.dateKey(
            for: Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now)!
        )
        let snap = snapshot(courses: [
            course(courseNo: "A", displayName: "TuesSkip", weekday: 2, periods: ["B"], skippedDates: [tomorrowKey]),
            course(courseNo: "B", displayName: "WedKeep", weekday: 3, periods: ["B"]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.displayName == "WedKeep")
            // Two days out, so the widget must name the weekday instead of
            // saying "Tomorrow".
            #expect(info.day == .later(weekday: 3))
        } else {
            Issue.record("Expected .tomorrowFirst with Wednesday's course, got \(derived)")
        }
    }

    /// A course meeting twice in a day gets a row per block, not one row spanning the gap.
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

    /// A course in a different room for each block shows the room of the block in question,
    /// not every room joined, which the week grid cut to "TR-313, ...".
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
        // The week grid asks for a whole block, whose distinct rooms it lists.
        #expect(twoRooms.classroom(weekday: 1, periods: ["A", "B", "C"]) == "TR-313, IB-101")
    }

    /// Taipei's midnight wherever the device is, since the widget's day is Taipei's.
    @Test func nextMidnight_isTaipeiMidnight() {
        let taipei = WidgetTaipei.calendar
        let lateEvening = taipei.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 23, minute: 30))!
        let midnight = taipei.date(from: DateComponents(year: 2026, month: 9, day: 23))!
        #expect(WidgetTimelineDerivation.nextMidnight(after: lateEvening) == midnight)
        // At midnight itself the next one is a day later, never the same instant.
        let nextDay = taipei.date(from: DateComponents(year: 2026, month: 9, day: 24))!
        #expect(WidgetTimelineDerivation.nextMidnight(after: midnight) == nextDay)
    }

    /// The evening before a school holiday, the scan passes the holiday as today's check
    /// does, instead of offering its class as tomorrow's.
    @Test func holidayTomorrow_advancesToTheNextClassDay() {
        let now = monday(18, 0)
        let tomorrowKey = WidgetTimelineDerivation.dateKey(
            for: Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now)!
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
}
