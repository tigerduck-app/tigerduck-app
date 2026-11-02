import Foundation
import Testing
@testable import TigerDuck

struct ClubAPIModelsTests {
    static func envelope(_ rows: String) -> Data {
        Data(#"{"success":true,"data":[\#(rows)],"error":null,"meta":null}"#.utf8)
    }

    static func club(_ id: Int, _ name: String, en: String? = nil, attribute: String? = "學藝性", tagline: String? = nil) -> String {
        func json(_ value: String?) -> String { value.map { #""\#($0)""# } ?? "null" }
        return #"{"id":\#(id),"name":"\#(name)","en_name":\#(json(en)),"kind":"社團","attribute":\#(json(attribute)),"#
            + #""tagline":\#(json(tagline)),"tags":[],"recruit_status":null,"avatar_file_id":null,"banner_file_id":null}"#
    }

    static func activity(
        _ id: Int, club: Int, date: String? = "2026-11-03", endDate: String? = "2026-11-03",
        start: String? = "18:00:00", end: String? = "20:30:00", type: String = "社課或會議"
    ) -> String {
        func json(_ value: String?) -> String { value.map { #""\#($0)""# } ?? "null" }
        return #"{"id":\#(id),"name":"Meeting \#(id)","date":\#(json(date)),"end_date":\#(json(endDate)),"#
            + #""start_time":\#(json(start)),"end_time":\#(json(end)),"location":"S304","type":"\#(type)","#
            + #""content":"Line one\nLine two","club_id":\#(club),"club_name":"管樂社"}"#
    }

    @Test("the directory keeps every readable club and drops a row it cannot read")
    func directoryDecoding() throws {
        let body = Self.envelope([
            Self.club(93, "管樂社", en: "Wind Band", tagline: "歡迎"),
            #"{"id":2,"en_name":"No name"}"#,
            #""not a club""#,
            Self.club(33, "吉他社", attribute: nil),
        ].joined(separator: ","))

        let clubs = try ClubAPIList<ClubCard>.decode(body)

        #expect(clubs == [
            ClubCard(id: 93, name: "管樂社", enName: "Wind Band", attribute: "學藝性", tagline: "歡迎"),
            ClubCard(id: 33, name: "吉他社", enName: nil, attribute: nil, tagline: nil),
        ])
        #expect(try ClubAPIList<ClubCard>.decode(Self.envelope("")).isEmpty)
        #expect(throws: DecodingError.self) { try ClubAPIList<ClubCard>.decode(Data(#"{"success":false,"data":null}"#.utf8)) }
        #expect(throws: DecodingError.self) { try ClubAPIList<ClubCard>.decode(Data("<html>".utf8)) }
    }

    @Test("a Chinese interface shows the Chinese name; another shows the English one when there is one")
    func displayName() {
        let named = ClubCard(id: 1, name: "管樂社", enName: "Wind Band", attribute: nil, tagline: nil)
        let unnamed = ClubCard(id: 2, name: "吉他社", enName: nil, attribute: nil, tagline: nil)
        let blank = ClubCard(id: 3, name: "熱舞社", enName: "  ", attribute: nil, tagline: nil)

        #expect(named.displayName(chinese: true) == "管樂社")
        #expect(named.displayName(chinese: false) == "Wind Band")
        #expect(unnamed.displayName(chinese: false) == "吉他社")
        #expect(blank.displayName(chinese: false) == "熱舞社")
    }

    @Test("an activity's kind is a meeting, an event or one this build does not know")
    func kinds() throws {
        let body = Self.envelope([
            Self.activity(1, club: 41), Self.activity(2, club: 41, type: "活動"), Self.activity(3, club: 41, type: "講座"),
        ].joined(separator: ","))

        let kinds = try ClubAPIList<ClubActivity>.decode(body).map(\.kind)

        #expect(kinds == [.meeting, .event, .other("講座")])
    }

    @Test("only an activity that starts and ends on one day, with both times, has a place in the table")
    func oneDay() throws {
        let rows = [
            Self.activity(1, club: 41),
            Self.activity(2, club: 41, endDate: "2026-11-04"),
            Self.activity(3, club: 41, end: nil),
            Self.activity(4, club: 41, start: nil),
            Self.activity(5, club: 41, end: "18:00:00"),
            Self.activity(6, club: 41, end: "17:00:00"),
            Self.activity(7, club: 41, date: nil, endDate: nil),
            Self.activity(8, club: 41, start: "25:00:00"),
            Self.activity(9, club: 41, start: "18:00"),
            Self.activity(10, club: 41, start: "8:05:00", end: "23:59:00"),
        ]
        let activities = try ClubAPIList<ClubActivity>.decode(Self.envelope(rows.joined(separator: ",")))

        let placed = activities.compactMap { activity in activity.oneDay.map { [activity.id, $0.start, $0.end] } }

        #expect(placed == [[1, 1080, 1230], [10, 485, 1439]])
        #expect(activities.first?.oneDay?.day == "2026-11-03")
        #expect(activities.first?.content == "Line one\nLine two")
    }

    @Test("the directory's lifetime is its max-age, 300 seconds without one, and at most a day")
    func maxAge() {
        #expect(ClubAPIClient.maxAge("public, max-age=300") == 300)
        #expect(ClubAPIClient.maxAge("Max-Age=60, public") == 60)
        #expect(ClubAPIClient.maxAge("max-age=0") == 0)
        #expect(ClubAPIClient.maxAge(nil) == 300)
        #expect(ClubAPIClient.maxAge("no-cache") == 300)
        #expect(ClubAPIClient.maxAge("max-age=-5") == 300)
        #expect(ClubAPIClient.maxAge("max-age=soon") == 300)
        #expect(ClubAPIClient.maxAge("max-age=99999999") == 86_400)
    }

    @Test("an activity whose hour, minute or second is out of range has no place", arguments: ["08:60:00", "08:59:75", "200000000000000000:00:00", "24:00:00"])
    func outOfRangeTimes(time: String) throws {
        let read = try ClubAPIList<ClubActivity>.decode(Self.envelope(Self.activity(1, club: 93, start: time, end: "21:00:00")))

        #expect(try #require(read.first).oneDay == nil)
    }

    @Test("an answer whose every row is unreadable is a failure; an empty list and a partly readable one are not")
    func unreadableRows() throws {
        #expect(throws: DecodingError.self) { try ClubAPIList<ClubCard>.decode(Self.envelope(#"{"id":"x"},{"name":1}"#)) }
        #expect(try ClubAPIList<ClubCard>.decode(Self.envelope("")).isEmpty)
        #expect(try ClubAPIList<ClubCard>.decode(Self.envelope(#"{"id":"x"},"# + Self.club(1, "管樂社"))).map(\.id) == [1])
    }

    @Test("a club or an activity listed twice keeps its first row")
    func duplicateIDs() throws {
        let clubs = [Self.club(1, "管樂社"), Self.club(1, "吉他社"), Self.club(2, "熱舞社")]
        let activities = [Self.activity(5, club: 93), Self.activity(5, club: 41), Self.activity(6, club: 41)]

        #expect(try ClubAPIList<ClubCard>.decode(Self.envelope(clubs.joined(separator: ","))).map(\.name) == ["管樂社", "熱舞社"])
        #expect(try ClubAPIList<ClubActivity>.decode(Self.envelope(activities.joined(separator: ","))).map(\.clubID) == [93, 41])
    }

    @Test("an answer that ends on another host, after a redirect, is refused")
    func otherHostRefused() async {
        let base = SettingsAPIStub.uniqueBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = ClubAPIClient(baseURL: base, session: URLSession(configuration: config))
        var moved = SettingsAPIStub.StubResponse(statusCode: 200, body: Self.envelope(Self.club(1, "管樂社")))
        moved.url = URL(string: "https://elsewhere.invalid/api/v1/public/clubs")
        SettingsAPIStub.enqueue(moved, for: base.appending(path: "clubs"))

        var refusal: URLError?
        do { _ = try await client.clubs() } catch { refusal = error as? URLError }

        #expect(refusal?.code == .badServerResponse)
    }

    @Test("a failed fetch is reported for an unreadable answer or an unexpected status, not for a lost network or a cancellation")
    func reportedFailures() async {
        let base = SettingsAPIStub.uniqueBaseURL()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SettingsAPIStub.self]
        let client = ClubAPIClient(baseURL: base, session: URLSession(configuration: config))
        SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: base.appending(path: "clubs"))
        SettingsAPIStub.enqueue(.init(statusCode: 0, body: Data(), failure: .notConnectedToInternet), for: base.appending(path: "clubs"))

        func failure(_ body: () async throws -> Void) async -> (any Error)? {
            do { try await body() } catch { return error }
            return nil
        }
        let status = await failure { _ = try await client.clubs() }
        let offline = await failure { _ = try await client.clubs() }
        let unreadable = await failure { _ = try ClubAPIList<ClubCard>.decode(Data("{}".utf8)) }

        #expect(status.map(ClubAPIClient.isWorthReporting) == true)
        #expect(unreadable.map(ClubAPIClient.isWorthReporting) == true)
        #expect(offline.map(ClubAPIClient.isWorthReporting) == false)
        #expect(!ClubAPIClient.isWorthReporting(URLError(.timedOut)))
        #expect(!ClubAPIClient.isWorthReporting(URLError(.cancelled)))
        #expect(!ClubAPIClient.isWorthReporting(CancellationError()))
    }
}
