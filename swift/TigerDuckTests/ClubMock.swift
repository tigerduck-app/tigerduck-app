#if os(iOS)
import Defaults
import Foundation
import TigerDuckCore
@testable import TigerDuck

@MainActor
enum ClubMock {
    struct Club {
        let id: Int
        let zh: String
        let en: String
        let tagline: String?
    }

    struct Activity {
        let id: Int
        let club: Int
        let weekday: Int
        let start: String
        let end: String
        let name: String
        let location: String
        let type: String
        let content: String
    }

    static let clubs = [
        Club(id: 101, zh: "資訊安全研究社", en: "Information Security Club", tagline: "從 CTF 到漏洞研究，每週社課與讀書會"),
        Club(id: 102, zh: "絃韻吉他社", en: "Guitar Club", tagline: nil),
        Club(id: 103, zh: "管樂社", en: "Wind Band", tagline: "一起吹奏"),
        Club(id: 104, zh: "弓道社", en: "Kyudo Club", tagline: nil),
        Club(id: 105, zh: "美術社", en: "Art Club", tagline: "畫畫、展覽與寫生"),
        Club(id: 106, zh: "國際親善大使團", en: "International Ambassadors", tagline: nil),
    ]

    static let courses: [(no: String, weekday: Int, periods: [String])] = [
        ("MA2003301", 1, ["3", "4"]), ("GE3105701", 1, ["A"]), ("CS2001301", 2, ["6", "7"]),
        ("PE1010301", 3, ["2"]), ("FL1002701", 3, ["B", "C"]), ("EE2005301", 4, ["8", "9"]),
        ("CS4900301", 4, ["10"]), ("MA1001302", 5, ["1", "2"]),
    ]

    static let activities = [
        Activity(id: 1, club: 101, weekday: 1, start: "19:00", end: "21:00", name: "Web 漏洞實作：從 SQL Injection 到 SSRF",
                 location: "TR-412", type: "社課或會議", content: "帶筆電。\n本週練習 SQL Injection 與 SSRF。"),
        Activity(id: 2, club: 103, weekday: 1, start: "19:00", end: "21:30", name: "期末音樂會分部練習",
                 location: "學生活動中心 B1", type: "社課或會議", content: "請自備譜架。"),
        Activity(id: 3, club: 106, weekday: 3, start: "18:30", end: "21:00", name: "國際生迎新說明會",
                 location: "國際大樓 IB-101", type: "活動", content: ""),
        Activity(id: 4, club: 102, weekday: 3, start: "19:00", end: "21:00", name: "期中成發彩排",
                 location: "學生活動中心 2F", type: "活動", content: "彩排順序依社群公告。"),
        Activity(id: 5, club: 104, weekday: 4, start: "19:00", end: "20:30", name: "射法八節練習",
                 location: "弓道場", type: "社課或會議", content: ""),
        Activity(id: 6, club: 105, weekday: 5, start: "12:20", end: "13:00", name: "午間速寫",
                 location: "圖書館前廣場", type: "活動", content: ""),
        Activity(id: 7, club: 103, weekday: 5, start: "18:00", end: "20:00", name: "合奏練習",
                 location: "學生活動中心 B1", type: "社課或會議", content: ""),
        Activity(id: 8, club: 102, weekday: 6, start: "14:00", end: "17:00", name: "週末吉他工作坊",
                 location: "學生活動中心 2F", type: "活動", content: ""),
    ]

    static func minutes(_ time: String) -> Int {
        ClassTimeline.minutes(of: time) ?? 0
    }

    static func occurrences(on weekday: Int) -> [ClubOccurrence] {
        activities.filter { $0.weekday == weekday }.map { activity in
            let rank = clubs.firstIndex { $0.id == activity.club } ?? 0
            return ClubOccurrence(
                id: activity.id, clubID: activity.club, clubName: clubs[rank].zh,
                color: ClubSubscriptions.defaultColor(of: activity.club, palette: TigerDuckTheme.coursePaletteHexes),
                priority: rank, day: "2026-11-0\(activity.weekday + 1)", start: minutes(activity.start),
                end: minutes(activity.end), location: activity.location, kind: activity.type == "活動" ? .event : .meeting,
                name: activity.name, content: activity.content
            )
        }
    }

    static func courseTimes(on weekday: Int) -> [(start: Int, end: Int)] {
        courses.filter { $0.weekday == weekday }.flatMap(\.periods).compactMap { TimetablePeriod.byId[$0]?.minutes }
    }

    static func course(_ no: String, weekday: Int, periods: [String], semester: String) -> CourseStore.Course {
        CourseStore.Course(
            courseNo: no, courseName: no, instructor: "", credits: 3, classroom: "TR-313", enrolledCount: 40,
            maxCount: 60, schedule: [weekday: periods], semester: semester
        )
    }

    static func tableCourses(semester: String) -> [CourseStore.Course] {
        courses.map { course($0.no, weekday: $0.weekday, periods: $0.periods, semester: semester) }
    }

    struct Stores {
        let feed: ClubActivities
        let directory: ClubDirectory
        let subscriptions: ClubSubscriptions
        let root: URL
    }

    /// `dates` runs from Monday. Run inside `withExclusiveRealDefaults`.
    static func stores(dates: [Date], chinese: Bool = true) throws -> Stores {
        Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
        let subscriptions = ClubSubscriptions()
        for club in clubs { subscriptions.subscribe(club.id, for: testSignIn) }
        let root = FileManager.default.temporaryDirectory.appending(path: "ClubMock-\(UUID().uuidString)")
        let files = ClubFiles(folders: CacheFolders(root: root))
        files.saveDirectory(.init(body: try directoryBody(), storedAt: Date(), maxAge: 86_400))
        files.saveActivities(ETaggedBody(body: try feedBody(dates: dates), etag: #""mock""#))
        let directory = ClubDirectory(files: files, chinese: { chinese })
        let feed = ClubActivities(files: files, subscriptions: subscriptions, directory: directory)
        return Stores(feed: feed, directory: directory, subscriptions: subscriptions, root: root)
    }

    static func reset(_ stores: Stores) {
        Defaults.reset(.clubSubscriptions, .clubSubscriptionsPushPending)
        try? FileManager.default.removeItem(at: stores.root)
    }

    private static func envelope(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["success": true, "data": rows, "error": NSNull(), "meta": NSNull()])
    }

    private static func directoryBody() throws -> Data {
        try envelope(clubs.map { club in
            ["id": club.id, "name": club.zh, "en_name": club.en, "attribute": "學藝性",
             "tagline": club.tagline.map { $0 as Any } ?? NSNull()]
        })
    }

    private static func feedBody(dates: [Date]) throws -> Data {
        try envelope(activities.map { activity in
            let day = TaipeiTime.dayKey(for: dates[activity.weekday - 1])
            let club = clubs.first { $0.id == activity.club }
            return [
                "id": activity.id, "name": activity.name, "club_id": activity.club, "club_name": club?.zh ?? "",
                "date": day, "end_date": day, "start_time": activity.start + ":00", "end_time": activity.end + ":00",
                "location": activity.location, "type": activity.type, "content": activity.content,
            ]
        })
    }
}
#endif
