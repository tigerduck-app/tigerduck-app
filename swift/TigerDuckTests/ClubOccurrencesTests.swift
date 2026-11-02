import Defaults
import Foundation
import os
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct ClubOccurrencesTests {
    typealias Models = ClubAPIModelsTests

    private static func activities() throws -> [ClubActivity] {
        try ClubAPIList<ClubActivity>.decode(Models.envelope([
            Models.activity(1, club: 41, date: "2026-11-03", endDate: "2026-11-03", start: "19:00:00", end: "21:00:00"),
            Models.activity(2, club: 93, date: "2026-11-03", endDate: "2026-11-03", start: "18:00:00", end: "20:00:00"),
            Models.activity(3, club: 33, date: "2026-11-03", endDate: "2026-11-03", start: "18:00:00", end: "19:00:00", type: "活動"),
            Models.activity(4, club: 93, date: "2026-11-03", endDate: "2026-11-05"),
            Models.activity(5, club: 7, date: "2026-11-03", endDate: "2026-11-03"),
            Models.activity(6, club: 93, date: "2026-11-04", endDate: "2026-11-04", start: "12:10:00", end: "13:00:00"),
            Models.activity(7, club: 93, date: "2026-11-10", endDate: "2026-11-10"),
        ].joined(separator: ",")))
    }

    @Test("the subscribed clubs' one-day activities on the asked days, by day, start and priority")
    func occurrences() throws {
        let clubs: [(id: Int, color: UInt32)] = [(93, 0xD35400), (33, 0xC0392B), (41, 0x1ABC9C)]

        let shown = ClubActivities.occurrences(
            of: try Self.activities(), on: ["2026-11-03", "2026-11-04"], clubs: clubs, names: [93: "Wind Band", 41: "Guitar"]
        )

        #expect(shown.map(\.id) == [2, 3, 1, 6])
        #expect(shown.map(\.priority) == [0, 1, 2, 0])
        #expect(shown[0] == ClubOccurrence(
            id: 2, clubID: 93, clubName: "Wind Band", color: 0xD35400, priority: 0, day: "2026-11-03", start: 1080, end: 1200,
            location: "S304", kind: .meeting, name: "Meeting 2", content: "Line one\nLine two"
        ))
        #expect(shown[1].clubName == "管樂社")
        #expect(shown[1].kind == .event)
        #expect(ClubActivities.occurrences(of: try Self.activities(), on: ["2026-11-03"], clubs: [], names: [:]).isEmpty)
    }

    @Test("the store answers for Taipei days, with the subscriptions' colors and the directory's names")
    func storeOccurrences() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            defer { Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending) }
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = ClubFiles(folders: CacheFolders(root: root))
            files.saveActivities(ETaggedBody(body: Models.envelope(Models.activity(1, club: 93)), etag: nil))
            files.saveDirectory(.init(body: Models.envelope(Models.club(93, "管樂社", en: "Wind Band")), storedAt: Date(), maxAge: 300))
            let subscriptions = ClubSubscriptions()
            subscriptions.subscribe(93, for: testSignIn)
            let directory = ClubDirectory(files: files, chinese: { false })
            let feed = ClubActivities(files: files, subscriptions: subscriptions, directory: directory)
            let day = try #require(TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 23, minute: 30)))

            let shown = feed.occurrences(on: [day])

            #expect(shown.map(\.clubName) == ["Wind Band"])
            #expect(shown.map(\.color) == [0xD35400])
            #expect(feed.occurrences(on: [day.addingTimeInterval(3600)]).isEmpty)
        }
    }

    @Test("a search matches Chinese and English names, every word, ignoring case and width")
    func search() throws {
        let clubs = try ClubAPIList<ClubCard>.decode(Models.envelope([
            Models.club(1, "管樂社", en: "Wind Band"), Models.club(2, "吉他社", en: "Guitar Club"), Models.club(3, "熱舞社"),
        ].joined(separator: ",")))

        #expect(ClubDirectory.matching("吉他", in: clubs).map(\.id) == [2])
        #expect(ClubDirectory.matching("ｇｕｉｔａｒ", in: clubs).map(\.id) == [2])
        #expect(ClubDirectory.matching("club GUITAR", in: clubs).map(\.id) == [2])
        #expect(ClubDirectory.matching("band 吉他", in: clubs).isEmpty)
        #expect(ClubDirectory.matching("社", in: clubs).map(\.id) == [1, 2, 3])
        #expect(ClubDirectory.matching("  ", in: clubs).map(\.id) == [1, 2, 3])
    }

    @Test("the class table's refresh asks clubs.ntust.edu.tw only while a club is subscribed")
    func refreshOnlyWithSubscriptions() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            defer { Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending) }
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = ClubFiles(folders: CacheFolders(root: root))
            let base = SettingsAPIStub.uniqueBaseURL()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            let client = ClubAPIClient(baseURL: base, session: URLSession(configuration: config))
            let subscriptions = ClubSubscriptions()
            let directory = ClubDirectory(files: files, client: client)
            let feed = ClubActivities(files: files, client: client, subscriptions: subscriptions, directory: directory)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Models.envelope("")), for: base.appending(path: "activities"))
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Models.envelope("")), for: base.appending(path: "clubs"))

            #expect(SchoolRefresh.clubActivities(subscriptions: subscriptions, activities: feed, directory: directory) == nil)
            #expect(SettingsAPIStub.requests(under: base).isEmpty)

            subscriptions.subscribe(93, for: testSignIn)
            await SchoolRefresh.clubActivities(subscriptions: subscriptions, activities: feed, directory: directory)?.value
            #expect(Set(SettingsAPIStub.requests(under: base).compactMap { $0.url?.lastPathComponent }) == ["activities", "clubs"])
        }
    }

    @Test("a return to the app refreshes the club feed along with the course changes, as the first load does")
    func publicFeedsTakeTheClubs() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            defer { Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending) }
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = ClubFiles(folders: CacheFolders(root: root))
            let base = SettingsAPIStub.uniqueBaseURL()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            let client = ClubAPIClient(baseURL: base, session: URLSession(configuration: config))
            let subscriptions = ClubSubscriptions()
            subscriptions.subscribe(93, for: testSignIn)
            let directory = ClubDirectory(files: files, client: client, chinese: { true })
            let feed = ClubActivities(files: files, client: client, subscriptions: subscriptions, directory: directory)
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Models.envelope("")), for: base.appending(path: "activities"))
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Models.envelope("")), for: base.appending(path: "clubs"))

            await SchoolRefresh.publicFeeds(
                courseChanges: CourseChangeStore(hasCompletedOnboarding: { false }),
                subscriptions: subscriptions, activities: feed, directory: directory
            )?.value

            #expect(Set(SettingsAPIStub.requests(under: base).compactMap { $0.url?.lastPathComponent }) == ["activities", "clubs"])
        }
    }

    @Test("the class table's refresh does not wait for clubs.ntust.edu.tw, and the occurrences change once the feed lands")
    func refreshRunsAlongside() async throws {
        try await withExclusiveRealDefaults {
            Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
            defer { Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending) }
            let root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let files = ClubFiles(folders: CacheFolders(root: root))
            let base = SettingsAPIStub.uniqueBaseURL()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [SettingsAPIStub.self]
            let client = ClubAPIClient(baseURL: base, session: URLSession(configuration: config))
            let subscriptions = ClubSubscriptions()
            subscriptions.subscribe(93, for: testSignIn)
            let directory = ClubDirectory(files: files, client: client, chinese: { true })
            let feed = ClubActivities(files: files, client: client, subscriptions: subscriptions, directory: directory)
            let gate = SettingsAPIStub.ReplyGate()
            defer { gate.open() }
            var held = SettingsAPIStub.StubResponse(statusCode: 200, body: Models.envelope(Models.activity(1, club: 93)))
            held.gate = gate
            SettingsAPIStub.enqueue(held, for: base.appending(path: "activities"))
            SettingsAPIStub.enqueue(.init(statusCode: 200, body: Models.envelope("")), for: base.appending(path: "clubs"))
            let day = try #require(TaipeiTime.calendar.date(from: DateComponents(year: 2026, month: 11, day: 3, hour: 12)))
            let changed = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = feed.occurrences(on: [day]) } onChange: { changed.withLock { $0 = true } }

            let refresh = try #require(
                SchoolRefresh.clubActivities(subscriptions: subscriptions, activities: feed, directory: directory)
            )
            try await waitUntil { !SettingsAPIStub.requests(for: base.appending(path: "activities")).isEmpty }
            #expect(feed.activities.isEmpty)
            #expect(!changed.withLock { $0 })

            gate.open()
            await refresh.value
            try await waitUntil { changed.withLock { $0 } }
            #expect(feed.occurrences(on: [day]).map(\.id) == [1])
        }
    }
}
