#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailGuideURLTests {
    @Test func theEmbedURLCarriesThemeLanguageAndColours() {
        let url = MailGuide.embedURL(isDark: true, languageTag: "zh-Hant", background: 0x000000, foreground: 0xFFFFFF)
        #expect(url.absoluteString
            == "https://tigerduck.app/help/receive-mail/apple?embed=1&theme=dark&lang=zh-Hant&bg=%23000000&fg=%23ffffff")
    }

    /// A raw `#` would end the query at `bg=` and the page would get no colours at all.
    @Test func coloursNeverSendARawHash() {
        let url = MailGuide.embedURL(isDark: false, languageTag: "en", background: 0xFAFAFA, foreground: 0x111111)
        #expect(!url.absoluteString.contains("#"))
        #expect(url.absoluteString.contains("theme=light"))
        #expect(MailGuide.isGuideURL(url))
    }

    @Test(arguments: [
        "https://tigerduck.app/help/receive-mail/apple",
        "https://tigerduck.app/help/receive-mail/apple?embed=1",
        "https://tigerduck.app/help/receive-mail/other/",
        "https://TigerDuck.app/help/receive-mail/android",
    ])
    func theGuidesOwnPagesAreRecognized(url: String) {
        #expect(MailGuide.isGuideURL(URL(string: url)))
    }

    @Test(arguments: [
        "https://evil-tigerduck.app/help/receive-mail/apple",
        "https://tigerduck.app.evil.com/help/receive-mail/apple",
        "https://tigerduck.app@evil.com/help/receive-mail/apple",
        "https://user@tigerduck.app/help/receive-mail/apple",
        "https://evil.com/?next=https://tigerduck.app/help/receive-mail/apple",
        "https://tigerduck.app:8443/help/receive-mail/apple",
        "http://tigerduck.app/help/receive-mail/apple",
        "https://tigerduck.app/",
        "https://tigerduck.app/help/receive-mail/../../other",
        "javascript:alert(1)",
        "data:text/html,hi",
        "file:///help/receive-mail/apple",
        "not a url",
    ])
    func everythingElseIsNot(url: String) {
        #expect(!MailGuide.isGuideURL(URL(string: url)))
    }

    /// A subframe's own navigation is not a link the user tapped, so it never reaches the browser.
    @Test func onlyTheMainFrameOpensTheBrowser() {
        let offSite = URL(string: "https://example.com/")
        #expect(MailGuide.decision(for: offSite, isMainFrame: true) == .openExternally)
        #expect(MailGuide.decision(for: offSite, isMainFrame: false) == .refuse)
        let guide = URL(string: "https://tigerduck.app/help/receive-mail/apple")
        #expect(MailGuide.decision(for: guide, isMainFrame: false) == .allow)
        #expect(MailGuide.decision(for: guide, isMainFrame: true) == .allow)
    }

    /// WebKit only reports transport failures; an HTTP error page has to be caught by status.
    @Test func aMainFrameHTTPErrorIsAFailedLoad() {
        #expect(MailGuide.isLoadFailure(statusCode: 404, isMainFrame: true))
        #expect(MailGuide.isLoadFailure(statusCode: 502, isMainFrame: true))
        #expect(!MailGuide.isLoadFailure(statusCode: 404, isMainFrame: false))
        #expect(!MailGuide.isLoadFailure(statusCode: 200, isMainFrame: true))
    }

    @Test func aNavigationTheViewCancelledIsNotAFailure() {
        #expect(MailGuide.isIgnorable(NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)))
        #expect(MailGuide.isIgnorable(NSError(domain: "WebKitErrorDomain", code: 102)))
        #expect(!MailGuide.isIgnorable(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)))
    }

    @Test func aChosenLanguageIsSentAsChosen() {
        #expect(MailGuideView.languageTag(appLanguage: "en") == "en")
        #expect(MailGuideView.languageTag(appLanguage: "zh-Hant") == "zh-Hant")
        #expect(!MailGuideView.languageTag(appLanguage: LanguageManager.system).isEmpty)
    }
}
#endif
