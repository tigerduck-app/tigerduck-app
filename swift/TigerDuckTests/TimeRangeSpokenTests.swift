import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

struct TimeRangeSpokenTests {
    @Test func voiceOverHearsTheRangeInWords() {
        #expect(TimeRange.spoken("10:20", "12:10") == "10:20 to 12:10")
        #expect(TimeRange.spoken(from: 1140, to: 1260) == "19:00 to 21:00")
    }

    @Test func aClubShowsItsTimesAsARangeAndSpeaksThemInWords() throws {
        let club = try #require(ClubMock.occurrences(on: 1).first)
        #expect(club.details.contains(TimeRange.text(from: club.start, to: club.end)))
        #expect(club.spokenDetails.contains(TimeRange.spoken(from: club.start, to: club.end)))
        #expect(TimetableClubBlock.spoken(club).contains(TimeRange.spoken(from: club.start, to: club.end)))
    }
}
