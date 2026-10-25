#if os(iOS)
import Testing
import WebKit
@testable import TigerDuck

/// The find script in a real web view; listed in `on_screen_tests` in `.github/workflows/tests.yaml`.
@MainActor
struct BrowserFindPageTests {
    private static let body = """
    <p>作業 one</p><div contenteditable="true">作業 answer</div><svg><text>作業</text></svg>\
    <p style="display:none">作業 hidden</p><p>two 作業 and 作業</p><p>\(String(repeating: "a", count: 40))!</p>
    """

    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded?.resume() }
    }

    private func page(_ body: String = Self.body) async -> (WKWebView, BrowserFind) {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        let loader = Loader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { loader.loaded = $0; webView.loadHTMLString("<body>\(body)</body>", baseURL: nil) }
        withExtendedLifetime(loader) {}
        let find = BrowserFind()
        find.run = { [weak webView] in await webView?.runFind($0) }
        return (webView, find)
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async -> Any? {
        try? await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    @Test func marksShownTextAndLeavesEditableTextAndSVGAlone() async {
        let (webView, find) = await page()
        let before = await evaluate(webView, "return document.body.innerHTML") as? String
        find.query = "作業"
        await find.search()

        #expect(find.count == 3)
        #expect(await evaluate(webView, "return document.querySelector('[contenteditable]').innerHTML") as? String == "作業 answer")
        #expect(await evaluate(webView, "return document.querySelector('svg mark') === null") as? Bool == true)

        find.query = ""
        await find.search()
        #expect(await evaluate(webView, "return document.body.innerHTML") as? String == before)
    }

    @Test func matchesAPhraseSplitByFormattingButNotAcrossALineBreakOrBlock() async {
        let (webView, find) = await page("""
        <p>期<b>末</b>作業</p><p><b>assignment</b>
          <i>deadline</i></p><p>ab<br>cd</p><div>ef<p>gh</p></div>
        """)
        let before = await evaluate(webView, "return document.body.innerHTML") as? String

        find.query = "期末作業"
        await find.search()
        #expect(find.count == 1)
        #expect(await evaluate(webView, "return document.querySelectorAll('mark[data-tigerduck-find=\"0\"]').length") as? Int == 3)

        find.query = "assignment deadline"
        await find.search()
        #expect(find.count == 1)

        for query in ["bc", "fg"] {
            find.query = query
            await find.search()
            #expect(find.count == 0)
        }

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
