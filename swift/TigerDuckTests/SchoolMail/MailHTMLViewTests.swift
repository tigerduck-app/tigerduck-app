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
        var zoom = PageZoom.standard
        var height: CGFloat = 1
        var tappedLinks: [Int] = []
    }

    struct Host: View {
        let html: String
        var linkCount = 0
        var theme = MailHTMLTheme.app
        @Bindable var page: Page

        var body: some View {
            ScrollView {
                MailHTMLView(
                    html: html, linkCount: linkCount, inlineImages: [:], allowRemoteImages: false, theme: theme,
                    textZoom: page.zoom, contentHeight: $page.height,
                    onLinkTap: { page.tappedLinks.append($0) }
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
        let window = try Self.show(Host(html: Self.paragraph, page: page))
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
    }

    @Test("pinching the mail does not zoom it")
    func pinchZoomIsOff() async throws {
        let page = Page()
        let window = try Self.show(Host(html: Self.paragraph, page: page))
        defer { window.isHidden = true }
        try await waitUntil { page.height > 100 }
        _ = try await Self.settledHeight(of: page)

        let scroll = try #require(Self.webView(in: window)).scrollView
        #expect(scroll.minimumZoomScale == 1 && scroll.maximumZoomScale == 1)
        #expect(scroll.pinchGestureRecognizer?.isEnabled != true)
    }
}
#endif
