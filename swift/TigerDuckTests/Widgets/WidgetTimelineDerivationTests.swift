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

    private func course(courseNo: String, displayName: String, weekday: Int, periods: [String]) -> SnapshotCourse {
        SnapshotCourse(
            courseNo: courseNo,
            displayName: displayName,
            classroom: "",
            schedule: [weekday: periods],
            colorHex: 0
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
}
