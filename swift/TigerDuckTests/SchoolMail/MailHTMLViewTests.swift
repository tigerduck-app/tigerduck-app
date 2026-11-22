#if os(iOS)
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MailHTMLViewTests {
    @MainActor
    @Observable
    final class Page {
        var html = MailHTMLViewTests.paragraph
        var zoom = PageZoom.standard
        var height: CGFloat = 1
        var tappedLinks: [Int] = []
        var tappedImages: [String] = []
    }

    struct Host: View {
        var linkCount = 0
        var theme = MailHTMLTheme.app
        @Bindable var page: Page

        var body: some View {
            ScrollView {
                MailHTMLView(
                    html: page.html, linkCount: linkCount, inlineImages: [:], allowRemoteImages: false, theme: theme,
                    textZoom: page.zoom, contentHeight: $page.height,
                    onLinkTap: { page.tappedLinks.append($0) }, onImageTap: { page.tappedImages.append($0) }
                )
                .frame(height: page.height)
            }
        }
    }

    static let paragraph = "<p>" + String(repeating: "各位同學好，期末考試將於一月五日至一月九日舉行，請留意考試時間與教室。", count: 12) + "</p>"

    static func show(_ host: Host, width: CGFloat = 375, height: CGFloat = 800) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.rootViewController = UIHostingController(rootView: host)
        window.makeKeyAndVisible()
        return window
    }

    static func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        return view.subviews.lazy.compactMap { webView(in: $0) }.first
    }

    static func settledHeight(of page: Page) async throws -> CGFloat {
        var last = page.height
        var still = 0
        while still < 10 {
            try await Task.sleep(for: .milliseconds(50))
            still = page.height == last ? still + 1 : 0
            last = page.height
        }
        return last
    }

    @Test("the text size reflows the page within its width, and the height follows it up and down")
    func textSizeReflowsAndTheHeightFollows() async throws {
        let page = Page()
        let window = try Self.show(Host(page: page))
        defer { window.isHidden = true }
        try await waitUntil { page.height > 100 }
        let standard = try await Self.settledHeight(of: page)

        page.zoom = 200
        try await waitUntil { page.height > standard * 1.6 }
        let web = try #require(Self.webView(in: window))
        #expect(web.frame.width == 375)
        #expect(web.scrollView.contentSize.width <= 375, "no sideways scroll: \(web.scrollView.contentSize)")

        page.zoom = 50
        try await waitUntil { page.height < standard * 0.7 }
        #expect(try await Self.settledHeight(of: page) < standard * 0.7)
    }

    @Test("a shorter page in the same web view brings the height down")
    func aShorterPageBringsTheHeightDown() async throws {
        let page = Page()
        page.html = Self.paragraph + Self.paragraph
        let window = try Self.show(Host(page: page))
        defer { window.isHidden = true }
        try await waitUntil { page.height > 100 }
        let long = try await Self.settledHeight(of: page)

        page.html = "<p>短</p>"
        try await waitUntil { page.height < long / 4 }
        #expect(try await Self.settledHeight(of: page) < long / 4)
    }

    @Test("the first line starts at the page's top: the leading chain of first children loses its top margin, nothing else")
    func theFirstLineStartsAtThePagesTop() async throws {
        let page = Page()
        page.html = """
            <div id="wrapper" style="margin-top:20px"><table><tr><td><p id="first">第一行</p><p id="second">第二行</p></td></tr></table></div>\
            <blockquote id="quote"><p id="quoted">引文</p></blockquote>
            """
        let window = try Self.show(Host(page: page))
        defer { window.isHidden = true }
        try await waitUntil { page.height > 50 }
        let web = try #require(Self.webView(in: window))
        let probe = """
            const margin = id => getComputedStyle(document.getElementById(id)).marginTop;
            return ["wrapper", "first", "second", "quote", "quoted"].map(margin);
            """
        let found = try #require(try await web.callAsyncJavaScript(probe, in: nil, contentWorld: .defaultClient) as? [String])
        #expect(found.prefix(2).allSatisfy { $0 == "0px" }, "the first line's wrapper and paragraph: \(found)")
        #expect(found.dropFirst(2).allSatisfy { $0 != "0px" }, "margins past the first line: \(found)")
    }

    static let png: String = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let data = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80), format: format).pngData { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
        }
        return "data:image/png;base64,\(data.base64EncodedString())"
    }()

    /// Taps again while `done` does not hold: on iOS 26.5 a new window's first touch can go nowhere.
    static func tap(at point: CGPoint, in window: UIWindow, until done: () -> Bool) async throws {
        for _ in 0..<5 where !done() {
            window.makeKeyAndVisible()
            try await fingerTap(at: point, in: window)
            if try await PageMenuScreenTests.holds(within: .seconds(3), done) { return }
        }
        try await waitUntil(done)
    }

    static func imageCenter(_ index: Int, of web: WKWebView, in window: UIWindow) async throws -> CGPoint {
        let probe = "const r = document.images[\(index)].getBoundingClientRect(); return [r.x + r.width / 2, r.y + r.height / 2];"
        let point = try #require(
            try await web.callAsyncJavaScript(probe, in: nil, contentWorld: .defaultClient) as? [Double]
        )
        return web.convert(CGPoint(x: point[0], y: point[1]), to: window)
    }

    @Test("a tap on an image opens it, and a tap on an image inside a link stays the link's")
    func anImageTapIsTheImagesUnlessALinkHoldsIt() async throws {
        let html = Self.paragraph + "<p><img src=\"\(Self.png)\" width=\"120\" height=\"80\"></p>"
            + "<p><a href=\"https://link.invalid/0\"><img src=\"\(Self.png)\" width=\"120\" height=\"80\"></a></p>"
        let page = Page()
        page.html = html
        let window = try Self.show(Host(linkCount: 1, page: page), height: 1600)
        defer { window.isHidden = true }
        try await waitUntil { page.height > 300 }
        _ = try await Self.settledHeight(of: page)
        let web = try #require(Self.webView(in: window))

        #expect(await MailHTMLView.Coordinator.imageSource(at: CGPoint(x: 40, y: 40), in: web) == nil)
        try await fingerTap(at: web.convert(CGPoint(x: 40, y: 40), to: window), in: window)

        try await Self.tap(at: try await Self.imageCenter(0, of: web, in: window), in: window) { !page.tappedImages.isEmpty }
        #expect(page.tappedImages == [Self.png])

        try await Self.tap(at: try await Self.imageCenter(1, of: web, in: window), in: window) { !page.tappedLinks.isEmpty }
        #expect(page.tappedLinks == [0])
        #expect(page.tappedImages == [Self.png])
    }

    @Test("pinching the mail does not zoom it")
    func pinchZoomIsOff() async throws {
        let page = Page()
        let window = try Self.show(Host(page: page))
        defer { window.isHidden = true }
        try await waitUntil { page.height > 100 }
        _ = try await Self.settledHeight(of: page)

        let scroll = try #require(Self.webView(in: window)).scrollView
        #expect(scroll.minimumZoomScale == 1 && scroll.maximumZoomScale == 1)
        #expect(scroll.pinchGestureRecognizer?.isEnabled != true)
    }
}
#endif
