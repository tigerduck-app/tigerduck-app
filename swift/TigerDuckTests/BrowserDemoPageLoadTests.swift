#if os(iOS)
import Foundation
import Testing
import WebKit
@testable import TigerDuck

@MainActor
struct BrowserDemoPageLoadTests {
    private final class Recorder: NSObject, WKNavigationDelegate {
        var asked: [URL?] = []
        var finished = false

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            asked.append(action.request.url)
            decisionHandler(.allow)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finished = true
        }
    }

    @Test("WebKit asks only for about:blank when it shows a made page, the one load BrowserDemoPages allows")
    func madePageIsAskedForAsBlank() async throws {
        let url = URL(string: "https://courseselection.ntust.edu.tw/")!
        let blank = URL(string: "about:blank")!
        let recorder = Recorder()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 480))
        webView.navigationDelegate = recorder

        webView.loadHTMLString(DemoPortal.page(PortalLink(category: .curriculum, name: "Sample", url: url)), baseURL: nil)
        try await waitUntil { recorder.finished }

        #expect(recorder.asked == [blank])
        #expect(BrowserDemoPages().decide(blank) == .allow)
        #expect(webView.url == blank)
        #expect(try await webView.evaluateJavaScript("document.querySelector('h1').textContent") as? String == "Sample")
    }
}
#endif
