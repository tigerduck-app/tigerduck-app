#if os(iOS)
import Testing
import WebKit
@testable import TigerDuck

/// The find script in a real web view; listed in `on_screen_tests` in `.github/workflows/tests.yaml`.
@MainActor
struct BrowserFindPageTests {
    private static let body = """
    <p>作業 one</p>\
    <p style="display:none">作業 hidden</p><p>two 作業 and 作業</p><p>\(String(repeating: "a", count: 40))!</p>
    """

    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume() }
    }

    private func page() async -> (WKWebView, BrowserFind) {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let loader = Loader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { loader.loaded = $0; webView.loadHTMLString("<body>\(Self.body)</body>", baseURL: nil) }
        withExtendedLifetime(loader) {}
        let find = BrowserFind()
        find.run = { [weak webView] in await webView?.runFind($0) }
        return (webView, find)
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async -> Any? {
        try? await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    @Test func marksShownTextAndClearingRestoresThePage() async {
        let (webView, find) = await page()
        let before = await evaluate(webView, "return document.body.innerHTML") as? String
        find.query = "作業"
        await find.search()

        #expect(find.count == 3)

        find.query = ""
        await find.search()
        #expect(await evaluate(webView, "return document.body.innerHTML") as? String == before)
    }

    @Test(.timeLimit(.minutes(1)))
    func aSlowExpressionLeavesThePageResponsive() async {
        let (webView, find) = await page()
        find.query = BrowserFindMatcherTests.slowPattern
        find.mode = .regex
        await find.search()

        #expect(find.count == 0)
        let started = ContinuousClock.now
        #expect(await evaluate(webView, "return 1 + 1") as? Int == 2)
        #expect(ContinuousClock.now - started < .seconds(1))
    }
}
#endif
