import Defaults
import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

private nonisolated final class DemoSeriesRefusal: DemoRequestRefusal {
    static let series = SignInSeries()

    override class var signIns: SignInSeries { series }
}

@Suite("Demo account features", .serialized)
@MainActor
struct DemoFeatureDataTests {
    private static func day(_ text: String) throws -> Date { try #require(DemoTime.date(text)) }

    private static func writtenChanges(today: Date) throws -> (changes: CourseChanges, courses: [SDCourse]) {
        let folder = DemoAccountTests.Folder()
        let calls = DemoAccountTests.Calls()
        var account = DemoAccountTests.account(folder, calls: calls)
        account.now = { today }
        account.write(try #require(account.fixture), for: DemoAccountTests.demoSignIn())
        let courses = folder.cache.courses.loadCourses(semester: CourseSelectionService.currentSemesterCode())
        return (try CourseChanges(json: try #require(calls.courseChanges.last)), courses)
    }

    @Test("from a Tuesday, the midterm in another room falls on Wednesday and the class table underlines it")
    func courseChangesFillTheComingWeek() throws {
        let (changes, courses) = try Self.writtenChanges(today: try Self.day("2026-11-24T09:00"))
        let wednesday = try Self.day("2026-11-25")
        let thursday = try Self.day("2026-11-26")
        let dataStructures = try #require(courses.first { $0.courseNo == "CS3005301" })

        #expect(changes.hasAnswered)
        let midterm = try #require(CourseTimeSlot.changedMeetings(of: dataStructures, on: wednesday, changes: changes).first)
        #expect(midterm.assessment?.noteZh == "期中考")
        #expect(midterm.assessment?.noteEn == "Midterm exam")
        #expect(midterm.changes.compactMap(\.changedRoom) == ["TR-313"])
        #expect(changes.changes(courseNo: "CS3204301", on: thursday).map(\.kind) == [.online])
        #expect(changes.changes(courseNo: "EE2004301", on: thursday).compactMap(\.noteEn) == ["Make-up class"])
    }

    @Test("from a Thursday, the changes of Thursday are today's and Wednesday's are next week's")
    func courseChangesRollWithTheWeek() throws {
        let (changes, _) = try Self.writtenChanges(today: try Self.day("2026-11-26T20:00"))

        #expect(changes.days(courseNo: "CS3005301") == [try Self.day("2026-12-02")])
        #expect(changes.days(courseNo: "CS3204301") == [try Self.day("2026-11-26")])
    }

    @Test("the demo's transcript fills the score cache with the four regular terms before the current one")
    func transcriptFillsTheScoreCache() throws {
        let folder = DemoAccountTests.Folder()
        let account = DemoAccountTests.account(folder)
        let current = CourseSelectionService.currentSemesterCode()
        let earlier = (1...4).reduce(into: [try #require(AcademicTerm(code: current))]) { terms, _ in
            terms.append(terms[terms.count - 1].previousRegular)
        }.dropFirst().map(\.code).reversed()

        account.write(try #require(account.fixture), for: DemoAccountTests.demoSignIn())
        let files = ScoreReportFiles(folders: folder.cache.folders)
        let report = try #require(files.loadScoreReport(studentId: DemoAccountTests.studentId)).report

        #expect(report.student == "Demo Student")
        #expect(report.currentTerm == current)
        #expect(report.rankings.map(\.term) == Array(earlier))
        #expect(Set(report.courses.map(\.term)) == Set(earlier))
        #expect(report.courses.count == 24)
        #expect(report.creditSummary.earned.total == 58)
        #expect(report.creditSummary.enrolled.total == 12)
        #expect(GPATrendPoint.trend(for: report).map(\.semester.gpa) == [3.85, 3.59, 3.89, 3.57])

        let shown = ScoreViewModel(
            reports: ScoreReports(stored: { NTUSTScoreService.cachedScoreReport(studentId: $0, files: files) })
        )
        shown.showCachedReport(for: DemoAccountTests.studentId)
        #expect(shown.hasContent)
        #expect(shown.groupedCourses.map(\.term) == Array(earlier.reversed()))
    }

    @Test("a transcript written for a demo sign-in that has ended is not kept")
    func aTranscriptOfAnEndedSignInIsNotKept() throws {
        let folder = DemoAccountTests.Folder()
        let account = DemoAccountTests.account(folder)
        let signIns = SignInSeries()
        signIns.startDemo()
        let ended = signIns.currentSignIn
        signIns.end()

        account.write(try #require(account.fixture), for: ended)

        #expect(ScoreReportFiles(folders: folder.cache.folders).loadScoreReport(studentId: DemoAccountTests.studentId) == nil)
    }

    @Test("from a Tuesday, Wednesday's club activity is this week's and Monday's is next week's")
    func clubsFillTheComingWeek() throws {
        let calls = DemoAccountTests.Calls()
        var account = DemoAccountTests.account(DemoAccountTests.Folder(), calls: calls)
        let tuesday = try Self.day("2026-11-24T09:00")
        account.now = { tuesday }
        let fixture = try #require(account.fixture)
        let subscribed = (fixture.clubs ?? []).filter { $0.subscribed == true }.map(\.id)

        account.write(fixture, for: DemoAccountTests.demoSignIn())
        let names = Dictionary(uniqueKeysWithValues: calls.clubs.map { ($0.id, $0.displayName(chinese: false)) })
        let shown = ClubActivities.occurrences(
            of: calls.clubActivities, on: ["2026-11-24", "2026-11-25", "2026-11-30"],
            clubs: subscribed.map { (id: $0, color: UInt32(0)) }, names: names
        )

        #expect(calls.clubs.map(\.name) == ["開源技術開發研究社", "資訊安全研究社"])
        #expect(shown.map(\.day) == ["2026-11-25", "2026-11-30"])
        #expect(shown.map(\.clubName) == ["Open Source Technology Development Research Club", "Cyber Security Research Club"])
        #expect(calls.clubActivities.map(\.location) == ["TR-214", "TR-211"])
    }

    @Test("the demo's clubs stay through a refresh, which sends nothing, and leaving the demo shows the stored ones")
    func clubsNeedNoRequest() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsAPIStub.self]
        let client = ClubAPIClient(
            baseURL: base, session: URLSession(configuration: configuration.refusingDemoRequests(with: DemoSeriesRefusal.self))
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "DemoClubs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ClubFiles(folders: CacheFolders(root: root))
        let directory = ClubDirectory(files: files, client: client, chinese: { false })
        let feed = ClubActivities(files: files, client: client, subscriptions: ClubSubscriptions(), directory: directory)
        DemoSeriesRefusal.series.startDemo()
        defer { DemoSeriesRefusal.series.end() }
        let calls = DemoAccountTests.Calls()
        var account = DemoAccountTests.account(DemoAccountTests.Folder(), calls: calls)
        account.stores.showClubs = { clubs, activities in
            directory.show(clubs)
            feed.show(activities)
        }
        account.stores.dropClubs = { _, _, _ in
            directory.showStored()
            feed.showStored()
        }

        account.write(try #require(account.fixture), for: DemoSeriesRefusal.series.currentSignIn)
        await directory.refresh()
        await feed.refresh()

        #expect(directory.clubs.count == 2)
        #expect(directory.failure == nil)
        #expect(feed.activities.count == 2)
        #expect(SettingsAPIStub.requests(under: base).isEmpty)

        SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { account.leave(for: testSignIn, afterCurrentDemo: true) }
        #expect(directory.clubs.isEmpty)
        #expect(feed.activities.isEmpty)
    }

    @Test("a club fetch of the account before, answered after the demo shows its clubs, keeps nothing")
    func aClubFetchUnderWayKeepsNothing() async throws {
        let base = SettingsAPIStub.uniqueBaseURL()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsAPIStub.self]
        let client = ClubAPIClient(baseURL: base, session: URLSession(configuration: configuration))
        let root = FileManager.default.temporaryDirectory.appending(path: "DemoClubs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ClubFiles(folders: CacheFolders(root: root))
        let directory = ClubDirectory(files: files, client: client, chinese: { false })
        let feed = ClubActivities(files: files, client: client, subscriptions: ClubSubscriptions(), directory: directory)
        let envelope = { (rows: [[String: Any]]) in
            try JSONSerialization.data(withJSONObject: ["success": true, "data": rows, "error": NSNull(), "meta": NSNull()])
        }
        let day = TaipeiTime.dayKey(for: AppClock.now())
        let answered = SettingsAPIStub.ReplyGate()
        SettingsAPIStub.enqueue(
            .init(statusCode: 200, body: try envelope([["id": 1, "name": "籃球社", "en_name": "Basketball Club"]]), gate: answered),
            for: base.appending(path: "clubs")
        )
        SettingsAPIStub.enqueue(
            .init(
                statusCode: 200,
                body: try envelope([[
                    "id": 7, "name": "練球", "club_id": 1, "club_name": "籃球社", "date": day, "end_date": day,
                    "start_time": "18:00:00", "end_time": "20:00:00", "location": "", "type": "活動", "content": "",
                ]]),
                gate: answered
            ),
            for: base.appending(path: "activities")
        )
        var account = DemoAccountTests.account(DemoAccountTests.Folder())
        account.stores.showClubs = { clubs, activities in
            directory.show(clubs)
            feed.show(activities)
        }

        let fetches = Task {
            async let clubs: Void = directory.refresh()
            await feed.refresh()
            await clubs
        }
        try await waitUntil { SettingsAPIStub.requests(under: base).count == 2 }
        account.write(try #require(account.fixture), for: DemoAccountTests.demoSignIn())
        answered.open()
        answered.open()
        await fetches.value

        #expect(Set(directory.clubs.map(\.id)) == [990001, 990002])
        #expect(directory.failure == nil)
        #expect(feed.activities.map(\.id) == [991001, 991002])
        #expect(files.loadActivities() == nil)
    }

    @Test("a club fetch the demo refused leaves no failure once the stored directory shows again")
    func theStoredDirectoryShowsWithoutTheDemosFailure() async {
        let base = SettingsAPIStub.uniqueBaseURL()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsAPIStub.self]
        let client = ClubAPIClient(
            baseURL: base, session: URLSession(configuration: configuration.refusingDemoRequests(with: DemoSeriesRefusal.self))
        )
        let root = FileManager.default.temporaryDirectory.appending(path: "DemoClubs-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = ClubDirectory(files: ClubFiles(folders: CacheFolders(root: root)), client: client, chinese: { false })
        DemoSeriesRefusal.series.startDemo()
        defer { DemoSeriesRefusal.series.end() }

        await directory.refresh()
        #expect(directory.failure != nil)
        directory.showStored()

        #expect(directory.failure == nil)
        #expect(!directory.isUnderMaintenance)
    }

    @Test("the demo's course changes stay through a refresh, which sends nothing, and leaving the demo drops them")
    func courseChangesNeedNoRequest() async throws {
        try await withExclusiveRealDefaults {
            let saved = (Defaults[.courseChangesCache], Defaults[.courseChangesETag])
            defer {
                Defaults[.courseChangesCache] = saved.0
                Defaults[.courseChangesETag] = saved.1
            }
            let base = SettingsAPIStub.uniqueBaseURL()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [SettingsAPIStub.self]
            let store = CourseChangeStore(
                session: URLSession(configuration: configuration.refusingDemoRequests(with: DemoSeriesRefusal.self)),
                baseURL: { base }, hasCompletedOnboarding: { true }
            )
            DemoSeriesRefusal.series.startDemo()
            defer { DemoSeriesRefusal.series.end() }
            let account = DemoAccountTests.account(DemoAccountTests.Folder(), courseChanges: { store.replaceFeed($0) })
            let revision = store.revision

            account.write(try #require(account.fixture), for: DemoSeriesRefusal.series.currentSignIn)
            let written = Defaults[.courseChangesCache]
            #expect(await store.refresh() == false)

            #expect(store.revision != revision)
            #expect(Defaults[.courseChangesCache] == written)
            #expect(!CourseChanges.cached.days(courseNo: "CS3005301").isEmpty)
            #expect(SettingsAPIStub.requests(under: base).isEmpty)

            SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { account.leave(for: testSignIn, afterCurrentDemo: true) }
            #expect(CourseChanges.cached == .empty)
            #expect(Defaults[.courseChangesETag].isEmpty)
        }
    }
}
