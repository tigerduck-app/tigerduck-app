import Foundation
import Testing
import TigerDuckCore
@testable import TigerDuck

@MainActor
struct TimeRangeSpokenTests {
    @Test(arguments: zip(["en", "zh-Hant"], ["10:20 to 12:10", "10:20 至 12:10"]))
    func eachLanguageSpeaksTheRangeInWords(localization: String, spoken: String) throws {
        let path = try #require(Bundle.main.path(forResource: localization, ofType: "lproj"))
        let bundle = try #require(Bundle(path: path))
        #expect(TimeRange.spoken("10:20", "12:10") { bundle.localizedString(forKey: $0.key, value: nil, table: nil) } == spoken)
    }

    @Test func aClubShowsItsTimesAsARangeAndSpeaksThemInWords() throws {
        let club = try #require(ClubMock.occurrences(on: 1).first)
        #expect(club.details.contains(TimeRange.text(from: club.start, to: club.end)))
        #expect(club.spokenDetails.contains(TimeRange.spoken(from: club.start, to: club.end)))
        #expect(TimetableClubBlock.spoken(club).contains(TimeRange.spoken(from: club.start, to: club.end)))
    }

    @Test("the course sheet's time card shows the range and speaks it, or says the class is cancelled")
    func theCourseSheetTimeCard() {
        let course = SDCourse(
            courseNo: "TEST410", courseName: "Test", schedule: Dictionary(uniqueKeysWithValues: (1...7).map { ($0, ["3", "4"]) })
        )
        let weekly = CourseDetailRoomAndTime.time(of: course, times: nil, weekday: 1, meeting: nil)
        #expect(weekly.text == TimeRange.text("10:20", "12:10"))
        #expect(weekly.spoken == TimeRange.spoken("10:20", "12:10"))
        #expect(!weekly.isChanged)

        let tapped = CourseDetailRoomAndTime.time(of: course, times: ("14:20", "16:20"), weekday: 1, meeting: nil)
        #expect(tapped.text == TimeRange.text("14:20", "16:20"))
        #expect(tapped.spoken == TimeRange.spoken("14:20", "16:20"))

        let unscheduled = CourseDetailRoomAndTime.time(of: course, times: nil, weekday: nil, meeting: nil)
        #expect(unscheduled.text == "—")
    }
}
