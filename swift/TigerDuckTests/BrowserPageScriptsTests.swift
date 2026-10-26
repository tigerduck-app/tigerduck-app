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

    /// Dark Reader marks the root element while it recolors the page.
    private static let darkened = "return document.documentElement.getAttribute('data-darkreader-mode') === 'dynamic'"
    private static let colors = """
    var body = getComputedStyle(document.body);
    return [getComputedStyle(document.documentElement).backgroundColor, body.backgroundColor, body.color]
    """

    /// A browser web view with the page scripts, in a window of `style` as the system's appearance.
    private func browser(in style: UIUserInterfaceStyle) throws -> (UIWindow, WKWebView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = style
        window.makeKeyAndVisible()
        let configuration = WKWebViewConfiguration()
        BrowserPageScripts.addScripts(to: configuration.userContentController)
        let webView = WKWebView(frame: window.bounds, configuration: configuration)
        window.rootViewController?.view.addSubview(webView)
        return (window, webView)
    }

    private func eventually(_ condition: () async throws -> Bool) async throws -> Bool {
        for _ in 0..<100 {
            if try await condition() { return true }
            try await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    @Test(arguments: ["", "<body style=\"background:#fff\">"])
    func aDarkAppearanceDarkensALightPageAndTheBackgroundAboveIt(start: String) async throws {
        let (window, webView) = try browser(in: .dark)
        defer { window.isHidden = true }
        await load(webView, "\(start)\(Self.paragraph)<img style=\"width:10px;height:10px\">")

        #expect(try await eventually { try await brightnessBelowTheText(of: webView) < 0.3 })
        #expect(await evaluate(webView, Self.darkened) as? Bool == true)
        #expect(await evaluate(webView, "return [typeof DarkReader, typeof chrome]") as? [String] == ["undefined", "undefined"])
        #expect(await evaluate(webView, "return getComputedStyle(document.querySelector('img')).filter") as? String == "none")
        // What WebKit shows past the page's edges, under a top address bar too.
        #expect(try await eventually { Self.brightness(of: webView.underPageBackgroundColor, in: webView) < 0.3 })

        webView.mediaType = "print"
        let printed = await evaluate(webView, Self.colors) as? [String]
        webView.mediaType = nil
        webView.overrideUserInterfaceStyle = .light
        #expect(try await eventually { try await brightnessBelowTheText(of: webView) > 0.7 })
        #expect(await evaluate(webView, Self.darkened) as? Bool == false)
        #expect(try await eventually { Self.brightness(of: webView.underPageBackgroundColor, in: webView) > 0.7 })
        #expect(printed == (await evaluate(webView, Self.colors) as? [String]), "a print shows the page's own colors")
    }

    @Test func aPageWithItsOwnDarkStyleAndTheLightSettingAreLeftAlone() async throws {
        let (window, webView) = try browser(in: .dark)
        defer { window.isHidden = true }
        for ownDark in ["<meta name=\"color-scheme\" content=\"light dark\">", "<body style=\"background:#111;color:#eee\">"] {
            await load(webView, "\(ownDark)\(Self.paragraph)")
            #expect(await evaluate(webView, Self.darkened) as? Bool == false, "\(ownDark)")
        }
        #expect(await evaluate(webView, Self.colors) as? [String] == ["rgba(0, 0, 0, 0)", "rgb(17, 17, 17)", "rgb(238, 238, 238)"])

        webView.overrideUserInterfaceStyle = .light
        // The web view tells its page a new appearance a moment later.
        #expect(try await eventually { await evaluate(webView, "return matchMedia('(prefers-color-scheme: dark)').matches") as? Bool == false })
        await load(webView, Self.paragraph)
        #expect(await evaluate(webView, Self.darkened) as? Bool == false)
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

    private static func brightness(of color: UIColor, in view: UIView) -> CGFloat {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.resolvedColor(with: view.traitCollection).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return (red + green + blue) / 3
    }
}
#endif
