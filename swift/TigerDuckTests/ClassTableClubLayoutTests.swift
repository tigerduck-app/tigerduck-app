#if os(iOS)
import CoreGraphics
import Defaults
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClassTableClubLayoutTests {
    typealias Layout = ClassTableClubLayout

    static let cellHeight: CGFloat = 52
    static let rowPitch: CGFloat = 55
    /// Every period shows, as on the mock's table: its clubs reach period 5 and A to D.
    static let periods = AppConstants.Periods.chronologicalOrder.compactMap { TimetablePeriod.byId[$0]?.minutes }

    static func row(_ period: String) -> CGFloat {
        CGFloat(AppConstants.Periods.chronologicalOrder.firstIndex(of: period) ?? 0) * rowPitch
    }

    static func segments(on weekday: Int) -> [Layout.Segment] {
        Layout.segments(of: ClubMock.occurrences(on: weekday), courses: ClubMock.courseTimes(on: weekday))
    }

    static func blocks(on weekday: Int) -> [Layout.Block] {
        Layout.blocks(segments(on: weekday), periods: periods, rowPitch: rowPitch, cellHeight: cellHeight)
    }

    static func span(_ segment: Layout.Segment) -> String {
        "\(segment.occurrence.id) \(segment.start)-\(segment.end)"
    }

    static func isClose(_ value: CGFloat, _ expected: CGFloat) -> Bool {
        abs(value - expected) < 0.001
    }

    @Test("Monday: a course wins, and a lower club shows only where the higher one has ended")
    func monday() throws {
        // The security club's 19:00-21:00 after period A, which ends 19:15; the band's 19:00-21:30 after it.
        #expect(Self.segments(on: 1).map(Self.span) == ["1 1155-1260", "2 1260-1290"])

        let blocks = Self.blocks(on: 1)
        let security = try #require(blocks.first)
        let band = try #require(blocks.last)
        #expect(blocks.count == 2)
        #expect(security.top == Self.row("B"))
        #expect(Self.isClose(security.top + security.height, Self.row("C") + 52 * 45 / 50))
        #expect(security.showsName && security.showsLocation)
        #expect(Self.isClose(band.top, security.top + security.height + 3))
        #expect(Self.isClose(band.top + band.height, Self.row("D") + 52 * 20 / 50))
        #expect(band.showsName && !band.showsLocation)
    }

    @Test("Wednesday: two clubs cut short of B-C, and the shorter piece goes without its name")
    func wednesday() throws {
        // The guitar club's 19:00-21:00 ranks above the ambassadors' 18:30-21:00; B-C runs 19:20-21:05.
        #expect(Self.segments(on: 3).map(Self.span) == ["4 1140-1160", "4 1210-1215", "3 1110-1140"])

        let blocks = Self.blocks(on: 3)
        #expect(blocks.map(\.segment.occurrence.id) == [4, 3])
        let guitar = try #require(blocks.first)
        let ambassadors = try #require(blocks.last)
        #expect(Self.isClose(guitar.top, Self.row("A") + 52 * 35 / 50))
        #expect(Self.isClose(guitar.top + guitar.height, Self.row("B") - 3))
        #expect(!guitar.showsName)
        #expect(Self.isClose(ambassadors.top, Self.row("A") + 52 * 5 / 50))
        #expect(Self.isClose(ambassadors.top + ambassadors.height, guitar.top - 3))
        #expect(ambassadors.showsName && !ambassadors.showsLocation)
    }

    @Test("an activity starts at its share of the period it starts in")
    func proportionalStart() throws {
        let kyudo = try #require(Self.blocks(on: 4).first)
        #expect(Self.isClose(kyudo.top, Self.row("A") + 52 * 0.7))

        let band = try #require(Self.blocks(on: 5).first { $0.segment.occurrence.id == 7 })
        #expect(Self.isClose(band.top, Self.row("10") + 52 * 0.6))
    }

    @Test("an activity wholly under a course or a higher club is not drawn")
    func hidden() {
        let under = ClubMock.occurrences(on: 1).map { occurrence in
            ClubOccurrence(
                id: occurrence.id, clubID: occurrence.clubID, clubName: occurrence.clubName, color: occurrence.color,
                priority: occurrence.priority, day: occurrence.day, start: ClubMock.minutes("19:30"),
                end: ClubMock.minutes("20:00"), location: occurrence.location, kind: occurrence.kind,
                name: occurrence.name, content: occurrence.content
            )
        }
        let segments = Layout.segments(of: under, courses: ClubMock.courseTimes(on: 1))
        #expect(segments.map(\.occurrence.id) == [1])
        #expect(Layout.segments(of: under, courses: [(start: ClubMock.minutes("19:00"), end: ClubMock.minutes("21:00"))]).isEmpty)
    }

    @Test("a time outside the periods is held to the first row's top and the last row's bottom")
    func clamped() {
        func position(_ time: String) -> CGFloat {
            TimetableNowLine.position(
                minute: ClubMock.minutes(time), periods: Self.periods, rowPitch: Self.rowPitch, cellHeight: Self.cellHeight
            )
        }
        #expect(position("07:00") == 0)
        #expect(position("23:30") == Self.row("D") + 52)
        #expect(Self.isClose(position("19:17"), Self.row("B") - 3 + 3 * 2 / 5))
        #expect(TimetableNowLine.offset(minute: ClubMock.minutes("07:00"), periods: Self.periods, rowPitch: 55, cellHeight: 52) == nil)
    }

    @Test("a tap lists the drawn activities that meet the tapped one, highest ranked first")
    func overlapping() throws {
        let monday = Self.blocks(on: 1).map(\.segment.occurrence)
        let band = try #require(monday.last)
        #expect(Layout.overlapping(band, among: monday).map(\.id) == [1, 2])

        let thursday = Self.blocks(on: 4).map(\.segment.occurrence)
        #expect(try Layout.overlapping(#require(thursday.first), among: thursday).map(\.id) == [5])
    }

    @Test("a club's day opens its row and its weekend column, which the export leaves out")
    func rowsAndColumns() async throws {
        try await withExclusiveRealDefaults {
            let monday = Date(timeIntervalSince1970: 1_793_548_800)
            let dates = (0..<7).map { monday.addingTimeInterval(Double($0) * 86_400) }
            let stores = try ClubMock.stores(dates: dates)
            defer { ClubMock.reset(stores) }
            let grid = ClassTableGrid(clubFeed: stores.feed)
            grid.courses = ClubMock.tableCourses(semester: "1151")

            grid.showClubs(on: dates)

            #expect(grid.clubs.keys.sorted() == [1, 3, 4, 5, 6])
            #expect(grid.activeWeekdays == [1, 2, 3, 4, 5, 6])
            #expect(grid.activePeriods.map(\.id) == AppConstants.Periods.chronologicalOrder)
            #expect(grid.activeWeekdays(withClubs: false) == [1, 2, 3, 4, 5])
            #expect(grid.activePeriods(withClubs: false).map(\.id) == ["1", "2", "3", "4", "6", "7", "8", "9", "10", "A", "B", "C"])

            grid.showClubs(on: [])
            #expect(grid.clubs.isEmpty)
            #expect(grid.activeWeekdays == [1, 2, 3, 4, 5])
        }
    }
}
#endif
