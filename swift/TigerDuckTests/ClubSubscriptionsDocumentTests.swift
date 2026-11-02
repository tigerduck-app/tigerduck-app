import Foundation
import Testing
@testable import TigerDuck

struct ClubSubscriptionsDocumentTests {
    typealias Document = ClubSubscriptionsDocument

    static func at(_ minute: Int) -> Document.Stamp {
        Document.Stamp(Date(timeIntervalSince1970: 1_793_620_800 + TimeInterval(minute * 60)))
    }

    static func club(subscribed: Bool? = nil, _ subscribedAt: Int = 0, color: UInt32? = nil, _ colorAt: Int = 0) -> Document.Club {
        Document.Club(
            subscribed: subscribed.map { .init(value: $0, at: at(subscribedAt)) },
            color: color.map { .init(value: $0, at: at(colorAt)) }
        )
    }

    @Test(
        "a club's default color hashes its id into the course palette",
        arguments: [(93, 0xD35400), (33, 0xC0392B), (41, 0x1ABC9C), (128, 0xF1C40F), (39, 0x2ECC71), (110, 0x4ECDC4), (1, 0xDDA0DD)]
    )
    func defaultColor(id: Int, hex: Int) {
        #expect(ClubSubscriptions.defaultColor(of: id, palette: TigerDuckTheme.coursePaletteHexes) == UInt32(hex))
    }

    @Test("each value takes the side that set it later, so two devices' edits of different fields both stay")
    func laterWins() {
        let local = Document(
            clubs: [93: Self.club(subscribed: false, 5, color: 0x111111, 1), 33: Self.club(subscribed: true, 2, color: 0x222222, 2)],
            order: .init(value: [33], at: Self.at(2))
        )
        let server = Document(
            clubs: [93: Self.club(subscribed: true, 1, color: 0x333333, 4), 41: Self.club(subscribed: true, 3, color: 0x444444, 3)],
            order: .init(value: [93, 41], at: Self.at(3))
        )

        let merged = Document.merged(local: local, server: server)

        #expect(merged.clubs[93] == Self.club(subscribed: false, 5, color: 0x333333, 4))
        #expect(merged.clubs[33] == Self.club(subscribed: true, 2, color: 0x222222, 2))
        #expect(merged.clubs[41] == Self.club(subscribed: true, 3, color: 0x444444, 3))
        #expect(merged.order == .init(value: [93, 41], at: Self.at(3)))
        #expect(merged.subscribedIDs == [41, 33])
    }

    @Test("a tie keeps the server's value, and a value one side lacks comes from the other")
    func tiesAndMissingFields() {
        let local = Document(clubs: [93: Self.club(subscribed: true, 1, color: 0x111111, 1)], order: .init(value: [93], at: Self.at(1)))
        let server = Document(clubs: [93: Self.club(subscribed: false, 1)], order: .init(value: [], at: Self.at(1)))

        let merged = Document.merged(local: local, server: server)

        #expect(merged.clubs[93] == Self.club(subscribed: false, 1, color: 0x111111, 1))
        #expect(merged.order?.value == [])
        #expect(Document.merged(local: Document(), server: server) == server)
        #expect(Document.merged(local: local, server: Document()) == local)
    }

    @Test("values another writer left unreadable or without a time read as absent, and the merge keeps the device's")
    func garbageIsIgnored() throws {
        let json = #"""
        {"clubs": {
            "93": {"subscribed": 1, "subscribed_at": "2026-11-02T14:00:00.000Z", "color": "red", "color_at": "2026-11-02T14:00:00Z"},
            "33": {"subscribed": "yes", "subscribed_at": "2026-11-02T14:00:00Z", "color": "#C0392B", "color_at": "later"},
            "41": {"subscribed": true, "color": "#1ABC9G", "color_at": "2026-11-02T14:00:00Z"},
            "128": {"subscribed": true, "subscribed_at": "2026-11-02T14:00:00.123456+00:00", "color": "#f1c40f", "color_at": "2026-11-02T14:00:00Z"},
            "039": {"subscribed": true, "subscribed_at": "2026-11-02T14:00:00Z"},
            "abc": {"subscribed": true, "subscribed_at": "2026-11-02T14:00:00Z"},
            "110": "subscribed",
            "1": {"subscribed": true, "subscribed_at": "2026-11-02T14:00:00Z", "color": "#DDA0DD0", "color_at": "2026-11-02T14:00:00Z"}
        },
         "order": {"ids": [128, "93", null, 1, 128], "at": "2026-11-02T14:00:00Z"}}
        """#
        let read = Document(json: Data(json.utf8))

        #expect(Set(read.clubs.keys) == [128, 1])
        #expect(read.clubs[128]?.color?.value == 0xF1C40F)
        #expect(read.clubs[128]?.subscribed?.at.text == "2026-11-02T14:00:00.123456+00:00")
        #expect(read.clubs[1]?.color == nil)
        #expect(read.order?.value == [128, 1, 128])
        #expect(read.subscribedIDs == [128, 1])

        let local = Document(clubs: [93: Self.club(subscribed: true, 0, color: 0xD35400, 0)])
        #expect(Document.merged(local: local, server: read).clubs[93] == local.clubs[93])

        for broken in ["[]", "null", "not json", #"{"clubs": [], "order": "93"}"#, #"{"order": {"ids": [93]}}"#] {
            #expect(Document(json: Data(broken.utf8)) == Document())
        }
    }

    @Test("a document reads back as written, its stamps' text unchanged")
    func roundTrip() throws {
        let server = try #require(Document.Stamp("2026-11-02T14:00:00.123456+00:00"))
        let document = Document(
            clubs: [93: .init(subscribed: .init(value: true, at: server), color: .init(value: 0x0000FF, at: Self.at(1))),
                    33: Self.club(subscribed: false, 2)],
            order: .init(value: [93], at: Self.at(3))
        )

        let written = document.json()
        let object = try #require(try JSONSerialization.jsonObject(with: written) as? [String: Any])
        let club = try #require((object["clubs"] as? [String: Any])?["93"] as? [String: Any])

        #expect(Document(json: written) == document)
        #expect(club["color"] as? String == "#0000FF")
        #expect(club["subscribed_at"] as? String == "2026-11-02T14:00:00.123456+00:00")
        #expect(Self.at(0).text == "2026-11-02T12:00:00.000Z")
    }

    @Test("the shown order is the user's order of subscribed clubs, then the rest by subscription time and id")
    func shownOrder() {
        let document = Document(
            clubs: [
                1: Self.club(subscribed: true, 9), 2: Self.club(subscribed: true, 4), 3: Self.club(subscribed: false, 5),
                4: Self.club(subscribed: true, 4), 5: Self.club(subscribed: true, 1), 6: Self.club(color: 0x123456),
            ],
            order: .init(value: [3, 5, 1, 5, 99], at: Self.at(6))
        )

        #expect(document.subscribedIDs == [5, 1, 2, 4])
        #expect(Document(clubs: document.clubs).subscribedIDs == [5, 2, 4, 1])
    }

    @Test("subscribing puts a club last with its default color, and a later subscription keeps the color it had")
    func subscribing() {
        var document = Document()
        document.subscribe(93, defaultColor: 0xD35400, at: Self.at(1))
        document.subscribe(33, defaultColor: 0xC0392B, at: Self.at(2))
        #expect(document.subscribedIDs == [93, 33])
        #expect(document.clubs[33] == Self.club(subscribed: true, 2, color: 0xC0392B, 2))
        #expect(document.order == .init(value: [93, 33], at: Self.at(2)))

        let subscribedTwice = document
        document.subscribe(33, defaultColor: 0, at: Self.at(3))
        #expect(document == subscribedTwice)

        document.setColor(0xFF0000, of: 93, at: Self.at(4))
        document.unsubscribe(93, at: Self.at(5))
        #expect(document.subscribedIDs == [33])
        #expect(document.clubs[93]?.color == .init(value: 0xFF0000, at: Self.at(4)))

        document.subscribe(93, defaultColor: 0xD35400, at: Self.at(6))
        #expect(document.subscribedIDs == [33, 93])
        #expect(document.clubs[93]?.color?.value == 0xFF0000)
    }

    @Test("reordering stamps the order only when it changes, and setting the same color changes nothing")
    func reorderingAndColors() {
        var document = Document()
        for (minute, id) in [93, 33, 41].enumerated() { document.subscribe(id, defaultColor: 0, at: Self.at(minute)) }
        let before = document

        document.reorder([93, 33, 41], at: Self.at(9))
        document.setColor(0, of: 93, at: Self.at(9))
        #expect(document == before)

        document.reorder([41, 7, 93, 41, 33], at: Self.at(10))
        #expect(document.order == .init(value: [41, 93, 33], at: Self.at(10)))

        document.setColor(0xAB_CDEF12, of: 41, at: Self.at(11))
        #expect(document.clubs[41]?.color?.value == 0xCDEF12)
    }
}
