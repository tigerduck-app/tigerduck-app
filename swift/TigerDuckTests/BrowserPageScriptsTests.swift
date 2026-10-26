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

    @Test func aDarkAppearanceDarkensOnlyAPageWithNoDarkStyleOfItsOwn() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let configuration = WKWebViewConfiguration()
        BrowserPageScripts.addScripts(to: configuration.userContentController)
        let webView = WKWebView(frame: window.bounds, configuration: configuration)
        window.rootViewController?.view.addSubview(webView)
        let filters = "return [getComputedStyle(document.documentElement).filter, getComputedStyle(document.querySelector('img')).filter]"
        let img = "<img style=\"width:10px;height:10px\">"

        await load(webView, "\(Self.paragraph)\(img)")
        #expect(await evaluate(webView, filters) as? [String] == ["none", "none"])
        webView.overrideUserInterfaceStyle = .dark
        try await waitUntil(timeout: .seconds(5)) { webView.traitCollection.userInterfaceStyle == .dark }
        var shown: [String] = []
        for _ in 0..<50 {
            shown = await evaluate(webView, filters) as? [String] ?? []
            if shown.first != "none" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(shown.count == 2 && shown.allSatisfy { $0.contains("invert(1)") }, "\(shown)")
        webView.mediaType = "print"
        #expect(await evaluate(webView, filters) as? [String] == ["none", "none"], "a print shows the page's own colors")
        webView.mediaType = nil

        for ownDark in ["<meta name=\"color-scheme\" content=\"light dark\">", "<body style=\"background:#111;color:#eee\">"] {
            await load(webView, "\(ownDark)\(Self.paragraph)\(img)")
            #expect(await evaluate(webView, filters) as? [String] == ["none", "none"], "\(ownDark)")
        }
    }

    @Test(arguments: ["", "<body style=\"background:#fff\">"])
    func aDarkenedPageIsDarkBelowItsTextToo(start: String) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .dark
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let configuration = WKWebViewConfiguration()
        BrowserPageScripts.addScripts(to: configuration.userContentController)
        let webView = WKWebView(frame: window.bounds, configuration: configuration)
        window.rootViewController?.view.addSubview(webView)

        await load(webView, "\(start)\(Self.paragraph)")
        for _ in 0..<50 {
            if await evaluate(webView, "return getComputedStyle(document.documentElement).filter") as? String != "none" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await brightnessBelowTheText(of: webView) < 0.3)

        webView.overrideUserInterfaceStyle = .light
        for _ in 0..<50 {
            if await evaluate(webView, "return getComputedStyle(document.documentElement).filter") as? String == "none" { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(try await brightnessBelowTheText(of: webView) > 0.7)
    }

    private func brightnessBelowTheText(of webView: WKWebView) async throws -> CGFloat {
        _ = await evaluate(webView, "await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))")
        let image = try await webView.takeSnapshot(configuration: nil)
        return try #require(Self.brightness(of: image, at: CGPoint(x: 200, y: 700)))
    }

    /// The mean of a snapshot pixel's color channels, from 0 for black to 1 for white.
    private static func brightness(of image: UIImage, at point: CGPoint) -> CGFloat? {
        guard let cgImage = image.cgImage, let data = cgImage.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let scale = CGFloat(cgImage.width) / image.size.width
        let pixel = bytes + Int(point.y * scale) * cgImage.bytesPerRow + Int(point.x * scale) * cgImage.bitsPerPixel / 8
        return (CGFloat(pixel[0]) + CGFloat(pixel[1]) + CGFloat(pixel[2])) / 765
    }
}
#endif
