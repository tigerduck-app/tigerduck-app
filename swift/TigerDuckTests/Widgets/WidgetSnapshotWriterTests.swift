import Foundation
import Testing
@testable import TigerDuck
import TigerDuckCore

@MainActor
struct WidgetSnapshotWriterTests {
    private struct NoReload: WidgetReloadCoordinator.Reloader {
        func reloadAllTimelines() {}
    }

    @MainActor
    private final class Accent {
        var hex = 0x007AFF
    }

    @MainActor
    private final class Screen {
        var isUnlocked = true
    }

    @Test func anAccentChangeRewritesTheSnapshot() async throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let accent = Accent()
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { accent.hex },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: NoReload())
        )
        writer.regenerate()
        #expect(store.readSnapshot()?.accentColorHex == 0x007AFF)

        accent.hex = 0xFF2D55
        NotificationCenter.default.post(name: AppConstants.accentColorDidChange, object: nil)

        try await waitUntil { store.readSnapshot()?.accentColorHex == 0xFF2D55 }
        withExtendedLifetime(writer) {}
    }

    @Test func anUnchangedSnapshotIsNeitherRewrittenNorReloaded() throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let coordinator = WidgetReloadCoordinator(reloader: NoReload())
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: coordinator
        )
        writer.regenerate()
        let written = try #require(store.readSnapshot())
        let reload = try #require(coordinator.pendingTask)

        writer.regenerate()

        #expect(store.readSnapshot()?.generatedAt == written.generatedAt)
        #expect(coordinator.pendingTask == reload)
        withExtendedLifetime(writer) {}
    }

    @Test func aLocaleChangeReloadsAnUnchangedSnapshot() async throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let coordinator = WidgetReloadCoordinator(reloader: NoReload())
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: coordinator
        )
        writer.regenerate()
        let reload = try #require(coordinator.pendingTask)

        NotificationCenter.default.post(name: NSLocale.currentLocaleDidChangeNotification, object: nil)

        try await waitUntil { coordinator.pendingTask != reload }
        withExtendedLifetime(writer) {}
    }

    /// A sync trigger's handler calls this right before it answers the push, after which iOS may
    /// suspend the app before the debounce ends (https://github.com/tigerduck-app/tigerduck-app/issues/664).
    @Test func aReloadNowSendsTheChangedSnapshotsReloadWithoutTheDebounce() async throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let reloads = WidgetReloadCoordinatorTests.FakeReloader()
        let timer = ManualSleeper()
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: reloads, sleep: { await timer.sleep(for: $0) })
        )

        writer.regenerateAndReloadNow()

        #expect(store.readSnapshot() != nil)
        #expect(reloads.callCount == 1)
        writer.regenerateAndReloadNow()
        #expect(reloads.callCount == 1)
    }

    @Test func aReloadNowSendsTheReloadAnEarlierRegenerateLeftWaiting() async throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let reloads = WidgetReloadCoordinatorTests.FakeReloader()
        let timer = ManualSleeper()
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: reloads, sleep: { await timer.sleep(for: $0) })
        )
        writer.regenerate()
        #expect(reloads.callCount == 0)

        writer.regenerateAndReloadNow()

        #expect(reloads.callCount == 1)
    }

    private static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        AcademicCalendar.calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    @Test func daysOutsideTheTermAreQuiet() {
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [
                SemesterTerm(code: "1151", start: Self.day(2026, 9, 14), end: Self.day(2027, 1, 8)),
                SemesterTerm(code: "1152", start: Self.day(2027, 2, 22), end: Self.day(2027, 6, 18)),
            ],
            holidays: [
                Holiday(
                    id: 1, nameZh: "國慶日", nameEn: "National Day",
                    start: Self.day(2026, 10, 10), end: Self.day(2026, 10, 10)
                ),
            ]
        )

        let keys = WidgetSnapshotWriter.quietDayKeys(
            calendar: calendar, optedIn: [], now: Self.day(2026, 9, 1).addingTimeInterval(9 * 3600)
        )

        #expect(keys.contains("2026-09-01"), "today, before the term begins")
        #expect(keys.contains("2026-09-13"), "the day before the term begins")
        #expect(!keys.contains("2026-09-14"), "the term's first day")
        #expect(keys.contains("2026-10-10"), "a holiday in the term")
        #expect(!keys.contains("2027-01-08"), "the term's last day")
        #expect(keys.contains("2027-01-09"), "between terms")
        #expect(keys.contains("2027-02-21"), "the day before the next term")
        #expect(!keys.contains("2027-02-22"), "the next term's first day")
        #expect(keys.contains("2027-06-19"), "after the last published term")
    }

    @Test func daysOutsideTheTermStopAYearAndAWeekOut() {
        let ended = AcademicCalendar(
            revision: 1,
            terms: [SemesterTerm(code: "1142", start: Self.day(2026, 2, 16), end: Self.day(2026, 6, 19))],
            holidays: []
        )
        let now = Self.day(2026, 10, 13).addingTimeInterval(9 * 3600)

        let keys = WidgetSnapshotWriter.quietDayKeys(calendar: ended, optedIn: [], now: now)

        #expect(keys.count == 373)
        #expect(keys.min() == "2026-10-13")
        #expect(keys.max() == "2027-10-20")
        #expect(WidgetSnapshotWriter.quietDayKeys(calendar: .empty, optedIn: [], now: now).isEmpty)
    }

    @Test func aYearOldSnapshotOffersNoClassAfterTheTerm() throws {
        let written = Self.day(2026, 10, 13).addingTimeInterval(9 * 3600)
        let lastDay = try #require(AcademicCalendar.calendar.date(byAdding: .day, value: 365, to: written))
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [
                SemesterTerm(
                    code: "1161", start: Self.day(2027, 9, 13), end: AcademicCalendar.startOfDay(lastDay)
                ),
            ],
            holidays: []
        )
        let everyDay = SDCourse(
            courseNo: "TEST100",
            courseName: "Test",
            schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        )
        let snapshot = WidgetSnapshotBuilder.build(.init(
            courses: [everyDay],
            customNames: [:],
            colorMap: [:],
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            now: written,
            quietDayKeys: WidgetSnapshotWriter.quietDayKeys(calendar: calendar, optedIn: [], now: written)
        ))

        let evening = lastDay.addingTimeInterval(11 * 3600)
        #expect(WidgetTimelineDerivation.derive(snapshot: snapshot, at: evening) == .noMoreClasses)
    }

    @Test func betweenTermsTheNextTermsFirstClassShows() {
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [
                SemesterTerm(code: "1151", start: Self.day(2026, 9, 14), end: Self.day(2027, 1, 8)),
                SemesterTerm(code: "1152", start: Self.day(2027, 2, 22), end: Self.day(2027, 6, 18)),
            ],
            holidays: []
        )
        let now = Self.day(2027, 2, 18).addingTimeInterval(10 * 3600 + 40 * 60)
        let snapshot = WidgetSnapshotBuilder.build(.init(
            courses: [
                SDCourse(courseNo: "THU100", courseName: "Thursday", schedule: [4: ["3", "4"]]),
                SDCourse(courseNo: "MON100", courseName: "Monday", schedule: [1: ["3", "4"]]),
            ],
            customNames: [:],
            colorMap: [:],
            isLoggedIn: true,
            accentColorHex: 0x007AFF,
            now: now,
            quietDayKeys: WidgetSnapshotWriter.quietDayKeys(calendar: calendar, optedIn: [], now: now)
        ))

        let derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: now)
        if case .tomorrowFirst(let info) = derived {
            #expect(info.course.courseNo == "MON100")
            #expect(info.startTime == "10:20")
            #expect(info.day == .later(weekday: 1))
        } else {
            Issue.record("Expected the next term's first class, got \(derived)")
        }
    }

    @Test func aYearOldWatchPayloadOffersNoClassAfterTheTerm() throws {
        let written = Self.day(2026, 10, 13).addingTimeInterval(9 * 3600)
        let lastDay = try #require(AcademicCalendar.calendar.date(byAdding: .day, value: 365, to: written))
        let calendar = AcademicCalendar(
            revision: 1,
            terms: [
                SemesterTerm(
                    code: "1161", start: Self.day(2027, 9, 13), end: AcademicCalendar.startOfDay(lastDay)
                ),
            ],
            holidays: []
        )
        let everyDay = SDCourse(
            courseNo: "TEST100",
            courseName: "Test",
            schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        )
        let payload = WatchPayloadEncoder.encode(
            courses: [everyDay], customNames: [:], accentHex: "#FF8800", syncedAt: written,
            loggedIn: true, languageTag: nil, visualPreset: .default,
            quietDays: WidgetSnapshotWriter.quietDayKeys(calendar: calendar, optedIn: [], now: written)
        )

        let evening = lastDay.addingTimeInterval(11 * 3600)
        let eveningBefore = try #require(AcademicCalendar.calendar.date(byAdding: .day, value: -1, to: evening))
        let before = NextClassResolver.resolve(courses: payload.courses, now: eveningBefore, quietDays: payload.quietDays)
        #expect(before.next != nil)
        #expect(before.nextDay == .tomorrow)
        let last = NextClassResolver.resolve(courses: payload.courses, now: evening, quietDays: payload.quietDays)
        #expect(last.next == nil)
    }

    /// Behind the lock screen the caches cannot be opened and read as empty, so a write then would
    /// leave the widgets showing no classes until the next one.
    @Test func aLockedPhoneKeepsTheLastSnapshot() {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: WidgetReloadCoordinator(reloader: NoReload()),
            isProtectedDataAvailable: { false }
        )

        writer.regenerate()

        #expect(store.readSnapshot() == nil)
    }

    @Test func aForcedReloadAskedForBehindTheLockScreenComesAtTheUnlock() throws {
        let suite = "WidgetSnapshotWriterTests.\(UUID().uuidString)"
        defer { UserDefaults().removePersistentDomain(forName: suite) }
        let store = WidgetSnapshotStore(appGroupIdentifier: suite)
        let coordinator = WidgetReloadCoordinator(reloader: NoReload())
        let screen = Screen()
        let writer = WidgetSnapshotWriter(
            isLoggedIn: { true },
            accentColorHex: { 0x007AFF },
            store: store,
            coordinator: coordinator,
            isProtectedDataAvailable: { screen.isUnlocked }
        )
        writer.regenerate()
        let reload = try #require(coordinator.pendingTask)

        screen.isUnlocked = false
        writer.regenerate(forceReload: true)
        screen.isUnlocked = true
        writer.regenerate()

        #expect(coordinator.pendingTask != reload)
    }
}
