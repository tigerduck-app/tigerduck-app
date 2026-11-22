#if os(iOS)
import Defaults
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TigerDuck

/// The mail has no attachment: the attachment list reads `AppEnvironment`, which the test host never builds.
@MainActor
@Suite(.serialized)
struct MailMessageScreenTests {
    static let width: CGFloat = 375
    static let menuLabel = String(localized: "school_mail_message_actions")
    static let smaller = String(localized: "school_mail_text_smaller")
    static let reset = String(localized: "school_mail_text_size_reset")
    static let larger = String(localized: "school_mail_text_larger")
    static let copied = String(localized: "school_mail_source_copied")
    static let copyAll = String(localized: "school_mail_copy_all")

    static let picture: Data = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 320), format: format).pngData { context in
            UIColor(red: 0.85, green: 0.87, blue: 0.9, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 320))
            UIColor(red: 0.2, green: 0.45, blue: 0.8, alpha: 1).setFill()
            for column in 0..<4 { context.fill(CGRect(x: 40 + column * 140, y: 60, width: 100, height: 200)) }
        }
    }()

    static let html = """
        <p>各位同學好：</p>
        <p>114 學年度第 1 學期期末考試將於 1 月 5 日至 1 月 9 日舉行，請留意各科考試時間與教室，並攜帶學生證應試。</p>
        <p>如需申請補考，請於 12 月 19 日前至<a href="https://www.example.edu.tw/exam">教務處網站</a>填寫申請表。</p>
        <p><img src="cid:classroom@x" width="600" height="320" alt="教室配置圖"></p>
        <p>教務處課務組 敬啟</p>
        """

    static func harness() -> MailMessageViewModelTests.Harness {
        var message = FakeMailClient.message(uid: 5, name: "教務處課務組", subject: "114-1 期末考試注意事項",
                                             text: nil, html: html)
        message.detail?.inlineImages = ["classroom@x": MailInlineImage(mimeType: "image/png", data: picture)]
        message.detail?.parts = [
            MailBodyPart(section: "2", contentType: "image/png", charset: nil, transferEncoding: "base64",
                         filename: "教室配置圖.png", contentID: "classroom@x", size: picture.count, isAttachment: false),
        ]
        return MailMessageViewModelTests.harness(message)
    }

    static func show(_ model: MailMessageViewModel, style: UIUserInterfaceStyle) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: NavigationStack { MailMessageView(viewModel: model) })
        window.makeKeyAndVisible()
        return window
    }

    static func settledBody(in window: UIWindow) async throws -> WKWebView {
        try await waitUntil { MailHTMLViewTests.webView(in: window).map { $0.frame.height > 200 } ?? false }
        let web = try #require(MailHTMLViewTests.webView(in: window))
        var last = web.frame.height
        var still = 0
        while still < 10 {
            try await Task.sleep(for: .milliseconds(50))
            still = web.frame.height == last ? still + 1 : 0
            last = web.frame.height
        }
        return web
    }

    /// A menu left open, its window hidden, keeps a later test's text field from becoming first
    /// responder.
    static func close(_ window: UIWindow) {
        var views: [UIView] = [window]
        while let view = views.popLast() {
            view.interactions.compactMap { $0 as? UIContextMenuInteraction }.forEach { $0.dismissMenu() }
            views += view.subviews
        }
        window.isHidden = true
    }

    static func save(_ window: UIWindow, as name: String) {
        window.saveSnapshot(as: "mail-text-size-\(name)-\(PageMenuScreenTests.language)")
    }

    struct Page: CustomTestStringConvertible {
        let name: String
        let style: UIUserInterfaceStyle
        let lightPage: Bool
        var zoom = PageZoom.standard

        var testDescription: String { name }

        static let all = [
            Page(name: "light-page-dark-app", style: .dark, lightPage: true),
            Page(name: "light-page-light-app", style: .light, lightPage: true),
            Page(name: "dark-page", style: .dark, lightPage: false),
            Page(name: "light-page-dark-app-150", style: .dark, lightPage: true, zoom: 150),
        ]
    }

    @Test("the body runs from edge to edge, its text in line with the header, at each page and size",
          arguments: Page.all)
    func bodyRunsEdgeToEdge(page: Page) async throws {
        try await withExclusiveRealDefaults {
            let saved = Defaults[.mailTextZoom]
            defer { Defaults[.mailTextZoom] = saved }
            Defaults[.mailTextZoom] = page.zoom
            let h = Self.harness()
            await h.model.load()
            h.model.viewsInLightMode = page.lightPage
            let window = try Self.show(h.model, style: page.style)
            defer { window.isHidden = true }

            let web = try await Self.settledBody(in: window)
            let frame = web.convert(web.bounds, to: window)
            #expect(frame.minX == 0 && frame.maxX == Self.width, "body at \(frame)")
            #expect(h.model.formattedOnLightPage == page.lightPage)
            let first = try #require(
                try await web.callAsyncJavaScript(
                    "const r = document.querySelector('p').getBoundingClientRect(); return [r.left, r.top];",
                    in: nil, contentWorld: .defaultClient
                ) as? [Double]
            )
            #expect(first[0] == Double(MailMessageView.sideInset))
            #expect(first[1] == (page.lightPage ? Double(MailMessageView.sideInset) : 0), "the first line's top")
            try await Task.sleep(for: .milliseconds(300))
            Self.save(window, as: page.name)
        }
    }

    @Test("the menu's first row changes the text size and stays open to show the new size")
    func menuChangesTheTextSize() async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let saved = Defaults[.mailTextZoom]
                defer { Defaults[.mailTextZoom] = saved }
                Defaults[.mailTextZoom] = PageZoom.standard
                let h = Self.harness()
                await h.model.load()
                let window = try Self.show(h.model, style: .dark)
                defer { Self.close(window) }
                let web = try await Self.settledBody(in: window)
                let standardHeight = web.frame.height

                let items = try await PageMenuScreenTests.openMenu(labeled: Self.menuLabel, in: window)
                Self.save(window, as: "menu")
                #expect(items.contains { $0.accessibilityLabel == Self.smaller } && items.contains { $0.accessibilityLabel == Self.larger })
                #expect(accessibilityElement(labeled: "\(Self.reset), 100%", in: window) != nil)

                try await PageMenuScreenTests.tap(try #require(items.first { $0.accessibilityLabel == Self.larger }), in: window)
                try await waitUntil { Defaults[.mailTextZoom] == 110 }
                try await waitUntil { accessibilityElement(labeled: "\(Self.reset), 110%", in: window) != nil }
                try await waitUntil { web.frame.height > standardHeight }
                Self.save(window, as: "menu-110")
            }
        }
    }

    @Test("at either end of the range, the button that would pass it is off", arguments: [50, 200])
    func theEndsOfTheRangeTurnTheirButtonOff(zoom: Int) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let saved = Defaults[.mailTextZoom]
                defer { Defaults[.mailTextZoom] = saved }
                Defaults[.mailTextZoom] = zoom
                let h = Self.harness()
                await h.model.load()
                let window = try Self.show(h.model, style: .dark)
                defer { Self.close(window) }
                _ = try await Self.settledBody(in: window)

                let items = try await PageMenuScreenTests.openMenu(labeled: Self.menuLabel, in: window)
                let off = zoom == 50 ? Self.smaller : Self.larger
                let on = zoom == 50 ? Self.larger : Self.smaller
                #expect(try #require(items.first { $0.accessibilityLabel == off }).accessibilityTraits.contains(.notEnabled))
                #expect(try !#require(items.first { $0.accessibilityLabel == on }).accessibilityTraits.contains(.notEnabled))
            }
        }
    }

    @Test("Copy all copies the source and says so in a toast")
    func copyAllSaysCopied() async throws {
        try await withAccessibilityAutomation {
            let h = Self.harness()
            await h.model.load()
            h.model.mode = .source
            await h.model.loadSource()
            #expect(h.model.source != nil)
            let window = try Self.show(h.model, style: .dark)
            defer { window.isHidden = true }
            UIPasteboard.general.string = "before"

            try await waitUntil { accessibilityElement(labeled: Self.copyAll, in: window) != nil }
            let button = try #require(accessibilityElement(labeled: Self.copyAll, in: window))
            #expect(button.accessibilityActivate())
            try await waitUntil { accessibilityElement(labeled: Self.copied, in: window) != nil }
            #expect(UIPasteboard.general.string == h.model.source)
            try await Task.sleep(for: .milliseconds(400))
            Self.save(window, as: "copied")
        }
    }
}
#endif
