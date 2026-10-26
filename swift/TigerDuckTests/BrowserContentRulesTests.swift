#if os(iOS)
import Testing
import WebKit
@testable import TigerDuck

@MainActor
struct BrowserContentRulesTests {
    @Test func webKitCompilesTheLogoutRules() async throws {
        let store = try #require(WKContentRuleListStore.default())
        let identifier = "TigerDuckBrowserLogoutTest"
        let rules = try await store.compileContentRuleList(
            forIdentifier: identifier,
            encodedContentRuleList: BrowserPageScripts.logoutRules
        )
        #expect(rules != nil)
        try await store.removeContentRuleList(forIdentifier: identifier)
    }
}
#endif
