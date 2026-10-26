#if os(iOS)
import Testing
import UIKit
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

    private func page(_ body: String = Self.body, head: String = "", in host: UIView? = nil) async -> (WKWebView, BrowserFind) {
        let webView = WKWebView(frame: host?.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 800))
        host?.addSubview(webView)
        let loader = Loader()
        webView.navigationDelegate = loader
        await withCheckedContinuation { loader.loaded = $0; webView.loadHTMLString("<head>\(head)</head><body>\(body)</body>", baseURL: nil) }
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

    @Test func endingKeepsThePageScriptsOwnTextNodes() async {
        let (webView, find) = await page("""
        <p id="p"></p><script>var p = document.getElementById('p'); p.append('ab', 'cd'); window.held = [...p.childNodes];</script>
        """)
        let held = "return [p.childNodes.length, ...held.map(node => node.isConnected + ' ' + node.data)]"
        for query in ["b", "bc", "abcd"] {
            find.query = query
            await find.search()
            #expect(find.count == 1, "\(query)")
            find.query = ""
            await find.search()
            #expect(await evaluate(webView, held) as? [AnyHashable] == [2, "true ab", "true cd"], "\(query)")
        }
    }

    @Test func findsTextInAnElementWithNoBoxOfItsOwn() async {
        let (webView, find) = await page("<p><span style=\"display:contents\">assignment <b>deadline</b></span></p>")
        for query in ["assignment", "assignment deadline"] {
            find.query = query
            await find.search()
            #expect(find.count == 1, "\(query)")
        }
        withExtendedLifetime(webView) {}
    }

    @Test func showsAMatchInAScrolledBoxBelowWhatIsOnScreen() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let gap = "<div style=\"height:2000px\"></div>"
        let box = "<div id=\"box\" style=\"height:300px;overflow:auto\">\(gap)作業\(gap)</div>"
        let viewport = "<meta name=\"viewport\" content=\"width=device-width\">"
        let (webView, find) = await page(gap + box + gap, head: viewport, in: window.rootViewController?.view)
        webView.scrollView.contentInset = UIEdgeInsets(top: 60, left: 0, bottom: 400, right: 0)
        _ = await evaluate(webView, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")

        find.query = "作業"
        await find.search()
        let scroll = webView.scrollView
        var settled = scroll.contentOffset.y
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if scroll.contentOffset.y == settled, settled > 0 { break }
            settled = scroll.contentOffset.y
        }
        let place = "var m = document.querySelector('mark').getBoundingClientRect(), b = document.getElementById('box').getBoundingClientRect(); "
            + "return [m.top - b.top, b.bottom - m.bottom, m.top, m.bottom]"
        let shown = try #require(await evaluate(webView, place) as? [Double])
        #expect(shown[0] >= 0 && shown[1] >= 0, "the match is scrolled out of its box: \(shown)")
        let inset = scroll.adjustedContentInset
        #expect(shown[2] >= inset.top && shown[3] <= webView.bounds.height - inset.bottom, "the match is off screen: \(shown)")
    }

    @Test func doesNotMatchAcrossSkippedTextOrAnEmptyBlockButDoesAcrossHiddenText() async {
        let (webView, find) = await page("""
        <p>ab<span contenteditable="true">XX</span>cd</p><div>ef<p></p>gh</div><p>ij<svg><text>XX</text></svg>kl</p>\
        <p>mn<span style="display:none">XX</span>op</p>
        """)
        for (query, count) in [("ab", 1), ("abcd", 0), ("fg", 0), ("jk", 0), ("mnop", 1)] {
            find.query = query
            await find.search()
            #expect(find.count == count, "\(query)")
        }
        withExtendedLifetime(webView) {}
    }

    @Test(arguments: [1.0, 1.5])
    func showsTheMatchInTheMiddleOfWhatTheBarsLeaveAndDimsTheRest(zoom: Double) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let rows = (0..<300).map { "<div style=\"height:20px\">\($0 == 200 ? "作業" : "")</div>" }.joined()
        let viewport = "<meta name=\"viewport\" content=\"width=device-width\"><style>body { zoom: \(zoom) }</style>"
        let (webView, find) = await page(rows, head: viewport, in: window.rootViewController?.view)
        // The browser's top bar, and a find bar with the keyboard under it over the lower half.
        webView.scrollView.contentInset = UIEdgeInsets(top: 60, left: 0, bottom: 400, right: 0)
        // The page's first frames after the load set its scroll, which would undo a scroll before them.
        _ = await evaluate(webView, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        let inset = webView.scrollView.adjustedContentInset
        let middle = (inset.top + webView.bounds.height - inset.bottom) / 2

        find.query = "作業"
        await find.search()
        let scroll = webView.scrollView
        var settled = scroll.contentOffset.y
        for _ in 0..<50 {
            try await Task.sleep(for: .milliseconds(100))
            if scroll.contentOffset.y == settled, settled > 0 { break }
            settled = scroll.contentOffset.y
        }
        let shown = await Self.rows(of: webView, at: 16) { $0.red > 0.9 && (0.6...0.8).contains($0.green) && $0.blue < 0.4 }
        let first = try #require(shown.first, "offset \(scroll.contentOffset.y), zoom \(scroll.zoomScale), band \(middle)")
        let last = try #require(shown.last)
        #expect(abs((first + last) / 2 - middle) < 3, "the match shows at \(first)...\(last), not around \(middle)")
        let dimmed = await Self.rows(of: webView, at: 300) { $0.red < 0.8 && $0.red > 0.4 }
        #expect(dimmed.count > Int(webView.bounds.height / 2), "the rest of the page is not dimmed")

        find.query = ""
        await find.search()
        #expect(await evaluate(webView, "return document.querySelector('[data-tigerduck-find-light]') === null") as? Bool == true)
    }

    private struct Pixel { let red, green, blue: CGFloat }

    /// The rows of the web view's snapshot, in points, whose pixel at `x` passes `test`.
    private static func rows(of webView: WKWebView, at x: CGFloat, _ test: (Pixel) -> Bool) async -> [CGFloat] {
        guard let image = try? await webView.takeSnapshot(configuration: nil), let cgImage = image.cgImage,
              let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let scale = CGFloat(cgImage.height) / webView.bounds.height
        let bgra = cgImage.bitmapInfo.contains(.byteOrder32Little)
        let column = Int(x * scale) * cgImage.bitsPerPixel / 8
        return (0..<cgImage.height).compactMap { row in
            let pixel = bytes + row * cgImage.bytesPerRow + column
            let (red, blue) = bgra ? (pixel[2], pixel[0]) : (pixel[0], pixel[2])
            let passes = test(Pixel(red: CGFloat(red) / 255, green: CGFloat(pixel[1]) / 255, blue: CGFloat(blue) / 255))
            return passes ? CGFloat(row) / scale : nil
        }
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
