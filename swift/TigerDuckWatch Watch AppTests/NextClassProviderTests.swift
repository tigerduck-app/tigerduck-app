import XCTest
import WidgetKit
import TigerDuckCore
@testable import TigerDuckWatch_Watch_App

final class NextClassProviderTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        AppClock.setOverride(nil)
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        AppClock.setOverride(nil)
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func course(
        _ id: String, weekday: Int, start: String, end: String, skippedDates: Set<String>? = nil
    ) -> WatchCourse {
        WatchCourse(
            id: id, courseNo: id, name: id, teacher: "",
            classroom: "", colorHex: "#FF8800",
            weekday: weekday, startHHmm: start, endHHmm: end, periodLabel: "",
            skippedDates: skippedDates
        )
    }

    private func snapshot(
        _ courses: [WatchCourse], quietDays: Set<String> = [], clockOverrideJSON: String? = nil
    ) -> WatchSnapshot {
        WatchSnapshot(
            courses: courses, accentHex: "#FF8800", syncedAtMs: 0, loggedIn: true, languageTag: nil,
            clockOverrideJSON: clockOverrideJSON, quietDays: quietDays
        )
    }

    private func mondayAt(_ hhmm: String, dayOffset: Int = 0) -> Date {
        let parts = hhmm.split(separator: ":").compactMap { Int($0) }
        let day = DateComponents(year: 2026, month: 5, day: 11 + dayOffset, hour: parts[0], minute: parts[1])
        return TaipeiTime.calendar.date(from: day)!
    }

    private func writeSnapshot(_ snapshot: WatchSnapshot) throws -> URL {
        let file = tempDir.appendingPathComponent("schedule.json")
        try JSONEncoder().encode(snapshot).write(to: file)
        return file
    }

    func test_timeline_onAHoliday_showsNoClassThatDay() {
        let now = mondayAt("09:00")
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tuesday = course("B", weekday: 2, start: "08:10", end: "09:00")
        let holiday = snapshot([monday, tuesday], quietDays: [TaipeiTime.dayKey(for: now)])

        let entries = NextClassProvider().timeline(for: holiday, now: now).entries

        let onTheHoliday = entries.filter { $0.date < mondayAt("00:00", dayOffset: 1) }
        XCTAssertEqual(onTheHoliday.map(\.date), [now])
        XCTAssertNil(onTheHoliday.first?.current)
        XCTAssertEqual(onTheHoliday.first?.next?.id, "B")
        XCTAssertEqual(onTheHoliday.first?.nextDay, .tomorrow)
        XCTAssertEqual(entries.first { $0.date == mondayAt("00:00", dayOffset: 1) }?.next?.id, "B")
    }

    func test_timeline_skippedClass_isNeitherShownNorABoundary() {
        let now = mondayAt("09:00")
        let skipped = course(
            "A", weekday: 1, start: "10:20", end: "11:10", skippedDates: [TaipeiTime.dayKey(for: now)]
        )
        let later = course("B", weekday: 1, start: "13:30", end: "14:20")

        let entries = NextClassProvider().timeline(for: snapshot([skipped, later]), now: now).entries

        XCTAssertFalse(entries.contains { $0.current?.id == "A" || ($0.next?.id == "A" && $0.nextDay == .today) })
        XCTAssertFalse(entries.contains { $0.date == mondayAt("10:20") || $0.date == mondayAt("11:10") })
        XCTAssertEqual(entries.first?.next?.id, "B")
        XCTAssertEqual(entries.first { $0.date == mondayAt("14:20") }?.nextDay, .later(weekday: 1))
    }

    func test_timeline_fromMidnight_showsTheNextDaysFirstClass() {
        let now = mondayAt("20:00")
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tuesday = course("B", weekday: 2, start: "08:10", end: "09:00")

        let entries = NextClassProvider().timeline(for: snapshot([monday, tuesday]), now: now).entries

        XCTAssertEqual(entries.first?.next?.id, "B")
        XCTAssertEqual(entries.first?.nextDay, .tomorrow)
        let atMidnight = entries.first { $0.date == mondayAt("00:00", dayOffset: 1) }
        XCTAssertNil(atMidnight?.current)
        XCTAssertEqual(atMidnight?.next?.id, "B")
        XCTAssertEqual(atMidnight?.nextDay, .today)
    }

    func test_timeline_fromTheEndOfTheLastClass_showsTomorrowsFirstClass() {
        let now = mondayAt("09:00")
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let tuesday = course("B", weekday: 2, start: "08:10", end: "09:00")

        let entries = NextClassProvider().timeline(for: snapshot([monday, tuesday]), now: now).entries

        let afterTheLastClass = entries.first { $0.date == mondayAt("11:10") }
        XCTAssertNil(afterTheLastClass?.current)
        XCTAssertEqual(afterTheLastClass?.next?.id, "B")
        XCTAssertEqual(afterTheLastClass?.nextDay, .tomorrow)
    }

    func test_relevance_risesOnlyWhenTheNextClassStartsWithin30Minutes() {
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")
        let mondayLater = course("C", weekday: 1, start: "11:20", end: "12:10")
        let entries = NextClassProvider().timeline(for: snapshot([monday, mondayLater]), now: mondayAt("09:00")).entries

        XCTAssertEqual(entries.first?.relevance?.score, 30)
        let beforeC = entries.first { $0.date == mondayAt("11:10") }?.relevance
        XCTAssertEqual(beforeC?.score, 90)
        XCTAssertEqual(beforeC?.duration, 600)
    }

    func test_relevance_staysLowForAClassOnALaterDay() {
        let monday = course("A", weekday: 1, start: "08:10", end: "09:00")
        let tuesday = course("B", weekday: 2, start: "08:10", end: "09:00")
        let holidayMorning = mondayAt("07:50")
        let provider = NextClassProvider()

        let holiday = snapshot([monday, tuesday], quietDays: [TaipeiTime.dayKey(for: holidayMorning)])
        let onTheHoliday = provider.timeline(for: holiday, now: holidayMorning).entries.first
        XCTAssertEqual(onTheHoliday?.next?.id, "B")
        XCTAssertEqual(onTheHoliday?.relevance?.score, 30)

        let fridayEvening = provider.timeline(for: snapshot([monday, tuesday]), now: mondayAt("20:00", dayOffset: 4))
        XCTAssertEqual(fridayEvening.entries.first?.nextDay, .later(weekday: 1))
        XCTAssertEqual(fridayEvening.entries.first?.relevance?.score, 30)
    }

    func test_relevance_countsTomorrowsClassFromTomorrowsDate() {
        let tuesdayPastMidnight = course("B", weekday: 2, start: "00:10", end: "01:00")

        let entry = NextClassProvider().timeline(for: snapshot([tuesdayPastMidnight]), now: mondayAt("23:50")).entries.first

        XCTAssertEqual(entry?.nextDay, .tomorrow)
        XCTAssertEqual(entry?.relevance?.score, 90)
        XCTAssertEqual(entry?.relevance?.duration, 1_200)
    }

    func test_timeline_datesEntriesAndTheReloadOnTheRealClock() {
        let now = mondayAt("09:00")
        AppClock.setOverride(ClockOverride(
            instant: now, frozen: false, savedAtReal: Date(timeIntervalSince1970: 1_800_000_000)
        ))
        let monday = course("A", weekday: 1, start: "10:20", end: "11:10")

        let timeline = NextClassProvider().timeline(for: snapshot([monday]), now: now)

        let classStart = timeline.entries.first { $0.current?.id == "A" }
        XCTAssertNotEqual(classStart?.date, mondayAt("10:20"))
        XCTAssertEqual(classStart?.date, AppClock.realTime(forApp: mondayAt("10:20")))
        XCTAssertEqual(timeline.policy, .after(AppClock.realTime(forApp: mondayAt("04:00", dayOffset: 1))))
    }

    func test_loadSnapshot_appliesThePhonesDebugClock() throws {
        let fake = ClockOverride(instant: mondayAt("10:45"), frozen: true, savedAtReal: Date())
        let json = String(decoding: try JSONEncoder().encode(fake), as: UTF8.self)
        let file = try writeSnapshot(snapshot([], clockOverrideJSON: json))

        _ = NextClassProvider(snapshotFileURL: file).loadSnapshot()

        XCTAssertEqual(AppClock.now(), fake.instant)
    }

    func test_loadSnapshot_unknownVisualPreset_keepsTheClasses() throws {
        let encoded = try JSONEncoder().encode(snapshot([course("A", weekday: 1, start: "10:20", end: "12:10")]))
        var cached = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        cached["visualPreset"] = "someFuturePreset"
        let file = tempDir.appendingPathComponent("schedule.json")
        try JSONSerialization.data(withJSONObject: cached).write(to: file)

        let loaded = NextClassProvider(snapshotFileURL: file).loadSnapshot()

        XCTAssertEqual(loaded?.courses.map(\.id), ["A"])
        XCTAssertEqual(loaded?.visualPreset, .default)
    }

    func test_loadSnapshot_withoutAnOverride_returnsToTheRealClock() throws {
        AppClock.setOverride(ClockOverride(instant: mondayAt("10:45"), frozen: true, savedAtReal: Date()))
        let file = try writeSnapshot(snapshot([]))

        _ = NextClassProvider(snapshotFileURL: file).loadSnapshot()

        XCTAssertNil(AppClock.currentOverride())
    }
}
