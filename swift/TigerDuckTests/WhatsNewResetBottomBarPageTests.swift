// The 2.3.0 reset-bottom-bar What's New page: who gets asked (only a user
// whose visible bar differs from the default) and that it's registered for
// the release. iPhone/iPad-only like the page; the test target also builds
// for macOS.
#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WhatsNewResetBottomBarPageTests {
    @Test func aCustomizedBarIsOfferedTheReset() {
        #expect(WhatsNewPage.offersBottomBarReset(
            configuredTabs: [.home, .announcements, .calendar],
            libraryEnabled: true
        ))
        #expect(WhatsNewPage.offersBottomBarReset(
            configuredTabs: [.classTable, .home, .calendar],
            libraryEnabled: true
        ))
    }

    @Test func theDefaultBarIsNotOfferedTheReset() {
        #expect(!WhatsNewPage.offersBottomBarReset(configuredTabs: AppFeature.defaultTabs, libraryEnabled: true))
    }

    @Test func aHiddenLibraryTabDoesNotCountAsADifference() {
        let withLibrary = AppFeature.defaultTabs + [.library]
        #expect(!WhatsNewPage.offersBottomBarReset(configuredTabs: withLibrary, libraryEnabled: false))
        #expect(WhatsNewPage.offersBottomBarReset(configuredTabs: withLibrary, libraryEnabled: true))
    }

    @Test func theResetPageIsRegisteredFor230() throws {
        let pages = try #require(WhatsNewCatalog.releases["2.3.0"])
        #expect(pages.map(\.id) == ["reset-bottom-bar"])
    }
}
#endif
