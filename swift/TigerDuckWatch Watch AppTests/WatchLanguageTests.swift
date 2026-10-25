import Foundation
import Testing
@testable import TigerDuckWatch_Watch_App

/// The string `localization`'s own lproj in the Watch app holds for `key`, whatever the test run's language.
func localizedValue(_ key: String, in localization: String) throws -> String {
    let path = try #require(Bundle.main.path(forResource: localization, ofType: "lproj"))
    return try #require(Bundle(path: path)).localizedString(forKey: key, value: nil, table: nil)
}

@MainActor
struct WatchLanguageTests {

    private let system = WatchLanguage(tag: nil)

    @Test func beforeATagArrives_theWatchsOwnLanguageIsUsed() {
        #expect(system.locale == .current)
        #expect(WatchLanguage(tag: "ja").locale.identifier == "ja")
        #expect(system.string("watch_no_upcoming_classes") == String(localized: "watch_no_upcoming_classes"))
    }

    @Test func libraryErrorsFollowTheLanguageChosenOnThePhone() throws {
        let zh = WatchLanguage(tag: "zh-Hant")
        let offline = WatchLibraryServiceError.message(for: WatchLibraryServiceError.offline, in: zh)
        #expect(offline == (try localizedValue("error_network_unavailable", in: "zh-Hant")))
        let timeout = URLError(.timedOut)
        #expect(WatchLibraryServiceError.message(for: timeout, in: zh) == timeout.localizedDescription)
    }

    @Test func aFormatFillsTheTemplateOfTheTagsLanguage() throws {
        let minutes = String(format: try localizedValue("watch_relative_minutes_ago_short", in: "zh-Hant"), 5)
        #expect(WatchLanguage(tag: "zh-Hant").format("watch_relative_minutes_ago_short", 5) == minutes)
    }
}
