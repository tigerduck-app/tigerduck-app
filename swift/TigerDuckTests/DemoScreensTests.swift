#if os(iOS)
import Defaults
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct DemoScreensTests {
    static let looks = [UIUserInterfaceStyle.light, .dark].map { ClubScreensTests.Look(style: $0, textSize: .large) }

    private static func name(_ screen: String, _ look: ClubScreensTests.Look) -> String {
        "demo-\(screen)-\(look.testDescription)"
    }

    /// Run inside `withExclusiveRealDefaults`.
    @MainActor
    private struct Clubs {
        let root = FileManager.default.temporaryDirectory.appending(path: "DemoClubScreens-\(UUID().uuidString)")
        let subscriptions = ClubSubscriptions()
        let directory: ClubDirectory
        let feed: ClubActivities

        init() {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            let files = ClubFiles(folders: CacheFolders(root: root))
            directory = ClubDirectory(files: files, chinese: { false })
            feed = ClubActivities(files: files, subscriptions: subscriptions, directory: directory)
        }

        func write(_ account: DemoAccount) throws {
            var account = account
            account.stores.showClubs = { clubs, activities in
                directory.show(clubs)
                feed.show(activities)
            }
            let fixture = try #require(account.fixture)
            account.write(fixture, for: DemoAccountTests.demoSignIn())
            for club in fixture.clubs ?? [] where club.subscribed == true { subscriptions.subscribe(club.id, for: testSignIn) }
        }

        func remove() {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test("the demo's class table underlines the coming midterm and shows the online class and the clubs", arguments: looks)
    func classTable(look: ClubScreensTests.Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let signIn = testSignIn
                let saved = (
                    Defaults[.classTableSelectedSemester, for: signIn], Defaults[.courseChangesCache],
                    Defaults[.showClassroomInClassTable]
                )
                let clubs = Clubs()
                defer {
                    Defaults[.classTableSelectedSemester, for: signIn] = saved.0
                    Defaults[.courseChangesCache] = saved.1
                    Defaults[.showClassroomInClassTable] = saved.2
                    clubs.remove()
                }
                let folder = DemoAccountTests.Folder()
                try clubs.write(DemoAccountTests.account(folder, courseChanges: { Defaults[.courseChangesCache] = $0 }))
                let model = ClassTableViewModel(
                    courses: folder.cache.courses, importedTables: folder.classmates, clubs: clubs.feed
                )
                let term = SchoolTerms.current
                Defaults[.showClassroomInClassTable] = true
                SchoolAccountKeys.pickSemester(term, for: signIn)
                model.pickSemester(term, for: signIn)
                model.reloadFromCache()
                model.grid.showClubs(on: (1...7).map { ClassTableViewModel.nextDate(onWeekday: $0, from: AppClock.now()) })
                #expect(model.showsThisWeek)
                #expect(model.grid.clubs.values.joined().count == 2)

                let table = VStack { TimetableGridView(viewModel: model); Spacer(minLength: 0) }
                    .padding(.top, 60)
                    .environment(AppPreferences())
                let window = try ClubScreensTests.show(table, look: look, height: 1100)
                defer { window.isHidden = true }
                let assessment = String(localized: "course_change_assessment")
                let kali = try #require(model.grid.clubs.values.joined().first { $0.clubID == 990002 })
                try await waitUntil {
                    exposedAccessibilityLabels(in: window).contains { $0.contains("Data Structures, \(assessment)") }
                        && accessibilityElement(labeled: TimetableClubBlock.spoken(kali), in: window) != nil
                }
                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: Self.name("class-table", look))

                let labels = exposedAccessibilityLabels(in: window)
                #expect(labels.contains { $0.contains("Operating Systems, \(String(localized: "course_change_online"))") })
            }
        }
    }

    @Test("the demo's two clubs fill the subscribe sheet", arguments: looks)
    func clubs(look: ClubScreensTests.Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let clubs = Clubs()
                defer { clubs.remove() }
                try clubs.write(DemoAccountTests.account(DemoAccountTests.Folder()))

                let sheet = ClubSubscribeSheet(signIn: testSignIn, directory: clubs.directory, subscriptions: clubs.subscriptions)
                let window = try ClubScreensTests.show(sheet, look: look, height: 900)
                defer { window.isHidden = true }
                try await waitUntil { ClubScreensTests.shows("Cyber Security Research Club", in: window) }
                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: Self.name("clubs", look))

                #expect(clubs.subscriptions.subscribedIDs == [990001, 990002])
            }
        }
    }

    @Test("the demo's transcript fills the score screen", arguments: looks)
    func scores(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let folder = DemoAccountTests.Folder()
            let account = DemoAccountTests.account(folder)
            account.write(try #require(account.fixture), for: DemoAccountTests.demoSignIn())
            let files = ScoreReportFiles(folders: folder.cache.folders)
            let shown = ScoreViewModel(
                reports: ScoreReports(stored: { NTUSTScoreService.cachedScoreReport(studentId: $0, files: files) })
            )
            shown.showCachedReport(for: DemoAccountTests.studentId)

            let screen = ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    ScoreTranscript(viewModel: shown, policy: VisualStylePolicy(preset: .default)) { _ in }
                }
                .padding(.vertical, TigerDuckTheme.Spacing.md)
            }
            .background(Color.backgroundPrimary)
            let window = try ClubScreensTests.show(screen, look: look, height: 1400)
            defer { window.isHidden = true }
            try await waitUntil { exposedAccessibilityTexts(in: window).contains { $0.contains("Algorithms") } }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: Self.name("scores", look))

            #expect(ClubScreensTests.shows("Demo Student", in: window))
        }
    }

    /// 09:00 in Taipei on the day the run starts, read once, so that the dates written and the day the
    /// screen shows agree across a midnight while the pictures still show the run's week.
    private static let day = TaipeiTime.calendar.startOfDay(for: AppClock.now()).addingTimeInterval(9 * 3600)

    private static func written(_ folder: DemoAccountTests.Folder, for signIn: SignIn) throws -> DemoAccount {
        var account = DemoAccountTests.account(folder)
        account.now = { day }
        account.write(try #require(DemoFixture.load(from: .main, today: day)), for: signIn)
        return account
    }

    @Test("the demo's home lists today's classes and the assignments due in the coming days", arguments: looks)
    func home(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let folder = DemoAccountTests.Folder()
            _ = try Self.written(folder, for: DemoAccountTests.demoSignIn())
            let courses = CanonicalCourseProvider(courses: folder.cache.courses).currentCourses()
            let due = folder.cache.assignments.loadAssignments().ofTimetable(courses).upcomingSorted()
            #expect(due.map(\.title) == ["Homework 3: Balanced Binary Trees", "Lab 2: Process Scheduling"])

            let screen = ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    TodayCourseCarousel(
                        courses: courses.coursesForToday(), hasAssignment: { no in due.contains { $0.courseNo == no } }
                    )
                    UpcomingAssignmentsView(assignments: due, policy: VisualStylePolicy(preset: .default), courses: courses)
                }
                .padding(.vertical, TigerDuckTheme.Spacing.md)
            }
            .background(Color.backgroundPrimary)
            .environment(AppPreferences())
            let window = try ClubScreensTests.show(screen, look: look, height: 1000)
            defer { window.isHidden = true }
            try await waitUntil { exposedAccessibilityTexts(in: window).contains { $0.contains("Lab 2: Process Scheduling") } }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: Self.name("home", look))
        }
    }

    @Test("the demo's calendar shows this month with today's deadline", arguments: looks)
    func calendar(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let folder = DemoAccountTests.Folder()
            let signIn = DemoAccountTests.demoSignIn()
            let context = try Self.written(folder, for: signIn).stores.moodle(DemoAccountTests.studentId, signIn)
            let model = CalendarViewModel(assignments: folder.cache.assignments, courses: folder.cache.courses)
            model.load { context }
            model.selectedDate = Self.day
            model.displayedMonth = Self.day
            let today = model.eventsForSelectedDate
            #expect(today.map(\.title) == ["Homework 3: Balanced Binary Trees"])

            let screen = ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    MonthCalendarView(viewModel: model)
                    Divider()
                    DayEventListView(date: model.selectedDate, events: today, assignment: model.assignment(for:))
                }
            }
            .background(Color.backgroundPrimary)
            .environment(AppPreferences())
            let window = try ClubScreensTests.show(screen, look: look, height: 1000)
            defer { window.isHidden = true }
            try await waitUntil { ClubScreensTests.shows(MonthCalendarView.title(of: model.displayedMonth), in: window) }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: Self.name("calendar", look))
        }
    }

    @Test("Data Structures lists its staff, auditor and students", arguments: looks)
    func members(look: ClubScreensTests.Look) async throws {
        try await withAccessibilityAutomation {
            let folder = DemoAccountTests.Folder()
            let moodle = try #require(DemoFixture.bundled?.moodle?.courses(in: .en))
            let store = MoodleCourseStore(
                courseId: 90501, termCourseIds: [90501],
                context: MoodleCacheContext(
                    account: DemoAccountTests.studentId, cache: folder.cache.moodle, signIn: DemoAccountTests.demoSignIn()
                ),
                api: MoodleCourseAPI.demo(moodle)
            )
            await store.refreshMembers()
            #expect(store.members.value?.members.count == 20)

            let list = NavigationStack {
                MoodleMembersView(store: store, policy: VisualStylePolicy(preset: .default)) { _ in }
            }
            let window = try ClubScreensTests.show(list, look: look, height: 1600)
            defer { window.isHidden = true }
            try await waitUntil { ClubScreensTests.shows("Tseng Kuan-Lin", in: window) }
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: Self.name("members", look))

            #expect(ClubScreensTests.shows("Wang Hsiao-Ming", in: window))
        }
    }
}
#endif
