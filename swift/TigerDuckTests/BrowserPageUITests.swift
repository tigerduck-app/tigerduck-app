#if os(iOS)
import Testing
import UIKit
import WebKit
@testable import TigerDuck

/// Listed in `on_screen_tests` in `.github/workflows/tests.yaml`.
@MainActor
@Suite(.serialized)
struct BrowserPageUITests {
    private static let site = URL(string: "https://dialog-test.ntust.edu.tw/form")!

    private static func webView(_ pageUI: BrowserPageUI, configuration: WKWebViewConfiguration) -> WKWebView {
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: configuration)
        webView.uiDelegate = pageUI
        return webView
    }

    @Test("a window the page opens goes to this page by the browser's rules, returning no window, and an empty one goes nowhere")
    func aWindowOpensHere() async throws {
        var opened: [URL?] = []
        let pageUI = BrowserPageUI { action, _ in opened.append(action.request.url) }
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let webView = Self.webView(pageUI, configuration: configuration)
        webView.loadHTMLString("<title>選課登記</title>", baseURL: Self.site)
        try await waitUntil { webView.title == "選課登記" }

        let next = "https://dialog-test.ntust.edu.tw/next"
        let windows = try await webView.evaluateJavaScript(
            "[window.open('\(next)'), window.open(), window.open('about:blank', 'blank')].map((opened) => opened === null)"
        )
        #expect(windows as? [Bool] == [true, true, true])
        #expect(opened == [URL(string: next)])
        withExtendedLifetime(pageUI) {}
    }

    private static func browsersWebView(_ page: BrowserPage, _ navigator: BrowserNavigator) throws -> WKWebView {
        let container = navigator.makeView(opening: site)
        // The start page would load from the network.
        page.signIn.load = { _ in }
        return try #require(container.subviews.compactMap { $0 as? WKWebView }.last)
    }

    @Test("the browser's own web view sends a window the page opens through the browser's rules")
    func theBrowsersWebViewOpensWindowsByItsRules() async throws {
        let page = BrowserPage()
        let navigator = BrowserNavigator(page: page, auth: nil)
        let webView = try Self.browsersWebView(page, navigator)
        webView.loadHTMLString("<title>選課登記</title>", baseURL: Self.site)
        try await waitUntil { webView.title == "選課登記" }

        let outside = try #require(URL(string: "https://example.invalid/form"))
        webView.configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        let opened = try await webView.evaluateJavaScript("window.open('\(outside.absoluteString)') === null")
        #expect(opened as? Bool == true)
        #expect(page.outside == outside)
        #expect(webView.url == Self.site)
        withExtendedLifetime(navigator) {}
    }
}
#endif
