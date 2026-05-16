import Foundation
import Testing
@testable import TigerDuck

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
        } else {
            Issue.record("Expected .tomorrowFirst, got \(derived)")
        }
    }

    @Test func noMoreClasses_atAll() {
        let snap = snapshot(courses: [])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: monday(9, 30))
        #expect(derived == .noMoreClasses)
    }

    /// Marking today's in-progress class as skipped must drop it out of `.ongoing`
    /// so the widget no longer shows the strikethrough class as the active slot.
    @Test func skippedToday_removesFromOngoing() {
        let now = monday(9, 30)
        let key = WidgetTimelineDerivation.dateKey(for: now)
        let snap = snapshot(courses: [
            course(courseNo: "A", displayName: "DS", weekday: 1, periods: ["B"], skippedDates: [key]),
        ])
        let derived = WidgetTimelineDerivation.derive(snapshot: snap, at: now)
        #expect(derived == .noMoreClasses)
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
        } else {
            Issue.record("Expected .tomorrowFirst with Wednesday's course, got \(derived)")
        }
    }
}
