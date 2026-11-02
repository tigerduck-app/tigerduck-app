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
}
