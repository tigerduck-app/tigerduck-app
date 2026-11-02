#if os(iOS)
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct BrowserAddressSheetTests {
    typealias Screen = TLSPinPromptTests.Screen

    private static let host = "suggestionbox.ntust.edu.tw"
    private static let refused = URL(string: "https://\(host)/")!
    private static let leaf = "0f0e"

    /// The browser's address sheet as `TigerDuckBrowserView` presents it.
    private struct Presenter: View {
        let page: BrowserPage
        @State var sheet: BrowserSheet? = .address
        @State private var afterSheet: (() -> Void)?

        var body: some View {
            Color.clear.sheet(item: $sheet, onDismiss: {
                afterSheet?()
                afterSheet = nil
            }) { shown in
                BrowserSheetView(page: page, sheet: shown, showsNavigation: false) { work in
                    afterSheet = work
                    sheet = nil
                }
            }
        }
    }

    /// The page before shows while its link to `refused` was refused.
    private static func refusedPage(checked: Bool = true) -> BrowserPage {
        let page = BrowserAtRiskTests.refusedPage(refused, leaf: leaf)
        if !checked { page.failure = .certificate(host: host) }
        return page
    }

    private static func window(_ page: BrowserPage, screen: Screen = Screen.all[0], sheet: BrowserSheet = .address) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        window.overrideUserInterfaceStyle = screen.style
        window.rootViewController = UIHostingController(rootView: Presenter(page: page, sheet: sheet))
        if let textSize = screen.textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
        window.makeKeyAndVisible()
        return window
    }

    private static func shownSheet(in window: UIWindow) async throws -> UIView {
        let root = try #require(window.rootViewController)
        let invalid = String(localized: "browser_certificate_invalid")
        try await waitUntil {
            root.presentedViewController.map { accessibilityElement(labeled: invalid, in: $0.view) != nil } == true
        }
        return try #require(root.presentedViewController?.view)
    }

    private static var acceptRisk: String { String(localized: "browser_certificate_accept_risk") }

    @Test("the refused page's address sheet offers to open it at the student's risk", arguments: Screen.all)
    func offersToOpenAtRisk(screen: Screen) async throws {
        try await withAccessibilityAutomation {
            let window = try Self.window(Self.refusedPage(), screen: screen)
            defer { window.isHidden = true }
            let sheet = try await Self.shownSheet(in: window)

            let button = try #require(accessibilityElement(labeled: Self.acceptRisk, in: sheet))
            #expect(button.accessibilityTraits.contains(.button))
            // Scrolled into view when large text pushes it off the screen.
            let list = try #require(sheet.descendants(ofType: UIScrollView.self).first { $0.window != nil })
            let end = list.contentSize.height - list.bounds.height + list.adjustedContentInset.bottom
            if end > 0 { list.setContentOffset(CGPoint(x: 0, y: end), animated: false) }
            try await Task.sleep(for: .milliseconds(300))
            let frame = button.accessibilityFrame
            #expect(frame.minX >= 0 && frame.maxX <= screen.width && frame.maxY <= screen.height)
            try await Task.sleep(for: .milliseconds(600))
            window.saveSnapshot(as: "browser-address-\(screen.name)")
        }
    }

    @Test("the sheet names the refused address, and opening it at risk loads that address in a store of its own")
    func openingAtRiskAcceptsTheLeaf() async throws {
        try await withAccessibilityAutomation {
            let page = Self.refusedPage()
            let window = try Self.window(page)
            defer { window.isHidden = true }
            let sheet = try await Self.shownSheet(in: window)
            #expect(accessibilityElement(labeled: Self.refused.absoluteString, in: sheet) != nil)
            #expect(accessibilityElement(labeled: try #require(page.address?.absoluteString), in: sheet) == nil)

            #expect(try #require(accessibilityElement(labeled: Self.acceptRisk, in: sheet)).accessibilityActivate())
            try await waitUntil { window.rootViewController?.presentedViewController == nil && page.failure == nil }
            #expect(page.openedAtRisk == Self.refused)
            #expect(!page.store.isPersistent)
            #expect(page.certificates.acceptance.allows(Self.leaf, from: Self.host))
            #expect(!BrowserPage().certificates.acceptance.allows(Self.leaf, from: Self.host))
        }
    }

    @Test("on a page opened at risk the More sheet's zoom buttons and desktop site toggle are disabled")
    func siteSettingsAreDisabledAtRisk() async throws {
        try await withAccessibilityAutomation {
            let atRisk = Self.refusedPage()
            atRisk.openAtRisk()
            for page in [BrowserPage(), atRisk] {
                let window = try Self.window(page, sheet: .more)
                defer { window.isHidden = true }
                let root = try #require(window.rootViewController)
                let zoomIn = String(localized: "browser_zoom_in")
                try await waitUntil { root.presentedViewController.map { accessibilityElement(labeled: zoomIn, in: $0.view) != nil } == true }
                let sheet = try #require(root.presentedViewController?.view)
                let controls = [zoomIn, String(localized: "browser_zoom_out"), 1.0.formatted(.percent), String(localized: "browser_desktop_site")]
                for label in controls {
                    let control = try #require(accessibilityElement(labeled: label, in: sheet))
                    #expect(control.accessibilityTraits.contains(.notEnabled) == page.isAtRisk, "\(label)")
                }
            }
        }
    }

    @Test("with no leaf known from the refusal, the sheet says it was refused and offers nothing")
    func nothingToAcceptWithoutASeenCertificate() async throws {
        try await withAccessibilityAutomation {
            let window = try Self.window(Self.refusedPage(checked: false))
            defer { window.isHidden = true }
            let sheet = try await Self.shownSheet(in: window)
            try await Task.sleep(for: .milliseconds(300))

            #expect(accessibilityElement(labeled: Self.acceptRisk, in: sheet) == nil)
        }
    }
}
#endif
