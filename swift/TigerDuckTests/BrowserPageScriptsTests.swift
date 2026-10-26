#if os(iOS)
import Testing
import UIKit
import WebKit
@testable import TigerDuck

/// The browser's page scripts in a real web view; listed in `on_screen_tests` in `.github/workflows/tests.yaml`.
@MainActor
struct BrowserPageScriptsTests {
    private final class Loader: NSObject, WKNavigationDelegate {
        var loaded: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.resume()
            loaded = nil
        }
    }

    private static let host = "pages.test"
    private static let paragraph = "<p id=\"p\">" + String(repeating: "Lorem ipsum dolor sit amet. ", count: 12) + "</p>"

    private func load(_ webView: WKWebView, _ html: String) async {
        let loader = Loader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { loader.loaded = $0; webView.loadHTMLString(html, baseURL: URL(string: "https://\(Self.host)/")) }
    }

    private func evaluate(_ webView: WKWebView, _ script: String) async -> Any? {
        try? await webView.callAsyncJavaScript(script, contentWorld: .page)
    }

    @Test func aSiteZoomGrowsThePageAndWrapsItsTextAgain() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 800))
        await load(webView, "<meta name=\"viewport\" content=\"width=device-width\">\(Self.paragraph)")
        let size = "var p = document.getElementById('p').getBoundingClientRect(); return [p.width, p.height, document.documentElement.scrollWidth]"
        let before = try #require(await evaluate(webView, size) as? [Double])

        _ = await evaluate(webView, BrowserPageScripts.zoom([Self.host: 150]))
        let zoomed = try #require(await evaluate(webView, size) as? [Double])
        #expect(zoomed[0] <= before[0], "the text stays within the page's width")
        #expect(zoomed[1] > before[1] * 1.5, "the text grows and wraps onto more lines")
        #expect(zoomed[2] <= 390, "nothing scrolls sideways")

        _ = await evaluate(webView, BrowserPageScripts.zoom(["other.test": 150]))
        #expect(await evaluate(webView, size) as? [Double] == before)
    }
}
#endif
