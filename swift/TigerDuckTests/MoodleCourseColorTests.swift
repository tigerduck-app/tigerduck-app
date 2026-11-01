import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MoodleCourseColorTests {
    private static let moodle = TigerDuckTheme.moodleCourseColors

    @Test("Moodle's ten course colours come out readable on both cards, picked by the id's last digit")
    func theTenColoursAreMoodlesMadeReadable() {
        #expect(Self.moodle == [
            0x569E9E, 0x5E96CF, 0x8F88E0, 0x8F9395, 0x00A685, 0x0984E3, 0x8B9498, 0xAF8C4C, 0xE16C96, 0x6C5CE7,
        ])
        #expect(TigerDuckTheme.moodleCourseColor(forCourseId: 4127) == 0xAF8C4C)
        #expect(TigerDuckTheme.moodleCourseColor(forCourseId: 90) == 0x569E9E)
    }
}
