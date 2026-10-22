import Foundation
import Testing
@testable import TigerDuck

struct ConfiguredTabsDecodeTests {
    @Test func unknownRawValueIsDroppedAndTheRestDecodes() throws {
        let data = try JSONEncoder().encode(["home", "somethingFromANewerBuild", "classTable"])
        #expect(AppState.decodeConfiguredTabs(data) == [.home, .classTable])
    }

    @Test func aHiddenFeatureIsDroppedAndOrderOfTheRestIsKept() throws {
        let data = try JSONEncoder().encode(["home", "schoolMail", "classTable"])
        #expect(AppState.decodeConfiguredTabs(data, isShown: { $0 != .schoolMail }) == [.home, .classTable])
    }

    #if os(iOS)
    @Test func theDefaultPredicateKeepsSchoolMailInThisDebugBuild() throws {
        let data = try JSONEncoder().encode(["home", "schoolMail"])
        #expect(AppState.decodeConfiguredTabs(data) == [.home, .schoolMail])
    }
    #endif

    @Test func nilOrGarbageDataFallsBackLikeBefore() {
        #expect(AppState.decodeConfiguredTabs(nil) == nil)
        #expect(AppState.decodeConfiguredTabs(Data("not json".utf8)) == nil)
    }

    @Test func filteringDownToNothingAlsoFallsBack() throws {
        let data = try JSONEncoder().encode(["schoolMail"])
        #expect(AppState.decodeConfiguredTabs(data, isShown: { _ in false }) == nil)
    }
}
