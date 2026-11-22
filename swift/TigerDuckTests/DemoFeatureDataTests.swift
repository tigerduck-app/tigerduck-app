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

            SecureStore.$sharedForTesting.withValue(MemoryKeychain.locked()) { account.leave() }
            #expect(CourseChanges.cached == .empty)
            #expect(Defaults[.courseChangesETag].isEmpty)
        }
    }
}
