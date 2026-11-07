#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct BrowserDownloadsScreenTests {
    typealias Screen = TLSPinPromptTests.Screen

    static let screens = Screen.all.filter { $0.width == 375 }

    private struct Presenter: View {
        let page: BrowserPage
        @State var sheet: BrowserSheet? = .more

        var body: some View {
            Color.clear.sheet(item: $sheet) { shown in
                BrowserSheetView(page: page, sheet: shown, showsNavigation: true) { _ in }
            }
        }
    }

    private static func page(in place: SavedDownloadsTests.Place) async throws -> BrowserPage {
        let downloads = BrowserDownloads(store: place.store, folder: place.root.appending(path: "page", directoryHint: .isDirectory))
        for (name, size) in [("課程大綱.pdf", 356_000), ("第三週講義.pptx", 12_600_000)] {
            let file = try place.download("", named: name)
            try Data(count: size).write(to: file)
            _ = await downloads.finish(downloads.start(name, request: nil) {}, file: file)
        }
        let request = URLRequest(url: URL(string: "https://moodle2.ntust.edu.tw/pluginfile.php/1/mod_resource/content/1/example.zip")!)
        _ = downloads.fail(downloads.start("作業一範例.zip", request: request) {})
        let running = downloads.start("期中專題說明.pdf", request: request) {}
        downloads.received(running, bytes: 2_100_000, of: 8_400_000)
        return BrowserPage(downloads: downloads)
    }

    private static func window(_ page: BrowserPage, screen: Screen) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        window.overrideUserInterfaceStyle = screen.style
        if let textSize = screen.textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
        window.rootViewController = UIHostingController(rootView: Presenter(page: page))
        window.makeKeyAndVisible()
        return window
    }

    private static func sheet(in window: UIWindow, showing label: String) async throws -> UIView {
        let root = try #require(window.rootViewController)
        try await waitUntil { root.presentedViewController.map { accessibilityElement(labeled: label, in: $0.view) != nil } == true }
        return try #require(root.presentedViewController?.view)
    }

    /// Nothing in the window is still being presented or pushed.
    private static func isSettled(_ window: UIWindow) -> Bool {
        var seen = Set<ObjectIdentifier>()
        var controllers = window.rootViewController.map { [$0] } ?? []
        while let controller = controllers.popLast() {
            guard seen.insert(ObjectIdentifier(controller)).inserted else { continue }
            guard !controller.isBeingPresented, controller.transitionCoordinator == nil else { return false }
            controllers += controller.children + [controller.presentedViewController].compactMap { $0 }
        }
        return true
    }

    private static func close(_ window: UIWindow) {
        window.rootViewController?.dismiss(animated: false)
        window.isHidden = true
    }

    private static func name(_ shot: String, _ screen: Screen) -> String {
        "browser-downloads-\(shot)-\(screen.name)-\(PageMenuScreenTests.language)"
    }

    @Test("the More sheet's downloads row shows the ring while a download runs and takes a tap at its top edge",
          arguments: screens)
    func menuRow(screen: Screen) async throws {
        try await withAccessibilityAutomation {
            let place = SavedDownloadsTests.Place()
            defer { place.remove() }
            let window = try Self.window(try await Self.page(in: place), screen: screen)
            defer { Self.close(window) }
            let title = String(localized: "browser_downloads")
            let sheet = try await Self.sheet(in: window, showing: title)
            let row = try #require(accessibilityElement(labeled: title, in: sheet))
            #expect(row.accessibilityValue == 0.25.formatted(.percent.precision(.fractionLength(0))))
            try await waitUntil { Self.isSettled(window) }
            window.saveSnapshot(as: Self.name("menu", screen))

            // The menu runs under the sheet's empty navigation bar, which must not take its first row's taps.
            let back = try #require(accessibilityElement(labeled: String(localized: "browser_back"), in: sheet))
            let top = CGPoint(x: back.accessibilityFrame.midX, y: back.accessibilityFrame.minY + 4)
            let hit = try #require(window.hitTest(top, with: nil))
            #expect(!sequence(first: hit, next: \.superview).contains { $0 is UINavigationBar }, "\(hit)")
        }
    }

    @Test("the list shows a running, a failed and two saved downloads, each with its button", arguments: screens)
    func list(screen: Screen) async throws {
        try await withAccessibilityAutomation {
            let place = SavedDownloadsTests.Place()
            defer { place.remove() }
            let window = try Self.window(try await Self.page(in: place), screen: screen)
            defer { Self.close(window) }
            let title = String(localized: "browser_downloads")
            #expect(try #require(accessibilityElement(labeled: title, in: try await Self.sheet(in: window, showing: title)))
                .accessibilityActivate())
            let cancel = String(localized: "browser_download_cancel")
            let sheet = try await Self.sheet(in: window, showing: cancel)
            try await waitUntil { accessibilityElement(labeled: String(localized: "action_retry"), in: sheet) != nil && Self.isSettled(window) }
            window.saveSnapshot(as: Self.name("list", screen))

            let texts = exposedAccessibilityTexts(in: sheet)
            #expect(texts.contains { $0.contains(String(format: String(localized: "browser_download_done"), "12.6 MB")) })
            #expect(texts.contains { $0.contains(String(format: String(localized: "browser_download_progress"), "2.1 MB / 8.4 MB")) })
            #expect(texts.contains { $0.contains(String(localized: "browser_download_failed")) })
            let clear = try #require(accessibilityElement(labeled: String(localized: "browser_downloads_clear"), in: sheet))
            #expect(!clear.accessibilityTraits.contains(.notEnabled))
            // A saved row offers Open in Files as an action of its own instead.
            #expect(accessibilityElement(labeled: String(localized: "browser_downloads_open_in_files"), in: sheet) == nil)
            let frames = try [cancel, String(localized: "action_retry")].map {
                try #require(accessibilityElement(labeled: $0, in: sheet), "\($0)").accessibilityFrame
            }
            #expect(frames.allSatisfy { $0.maxX <= screen.width + 0.5 && $0.width.rounded() >= 44 }, "\(frames)")
        }
    }

    @Test("a long press on a saved file offers open, share, open in Files and remove", arguments: screens)
    func longPressMenu(screen: Screen) async throws {
        try await withAccessibilityAutomation {
            let place = SavedDownloadsTests.Place()
            defer { place.remove() }
            let window = try Self.window(try await Self.page(in: place), screen: screen)
            defer { Self.close(window) }
            let title = String(localized: "browser_downloads")
            #expect(try #require(accessibilityElement(labeled: title, in: try await Self.sheet(in: window, showing: title)))
                .accessibilityActivate())
            let sheet = try await Self.sheet(in: window, showing: String(localized: "browser_download_cancel"))
            let saved = String(format: String(localized: "browser_download_done"), "12.6 MB")
            try await waitUntil { exposedAccessibilityTexts(in: sheet).contains { $0.contains(saved) } }
            // At the largest text the saved rows start below the screen.
            let list = try #require(sheet.descendants(ofType: UICollectionView.self).first)
            let below = try #require(Self.element(containing: saved, in: sheet)).accessibilityFrame
            list.scrollRectToVisible(list.convert(below, from: window.screen.coordinateSpace), animated: false)
            let screenFrame = window.convert(window.bounds, to: window.screen.coordinateSpace)
            try await waitUntil {
                Self.element(containing: saved, in: sheet).map { screenFrame.contains($0.accessibilityFrame) } == true
            }
            try await waitUntil { Self.isSettled(window) }
            let row = try #require(Self.element(containing: saved, in: sheet))
            let remove = String(localized: "action_remove")
            let actions = (row.accessibilityCustomActions ?? []).map(\.name)
            #expect(actions.filter { $0 == remove }.count == 1, "\(actions)")
            #expect(actions.filter { $0 == String(localized: "browser_downloads_open_in_files") }.count == 1, "\(actions)")
            let frame = row.accessibilityFrame
            let center = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace)
            try await fingerTap(at: center, in: window, holding: .milliseconds(1_200))
            try await waitUntil {
                [String(localized: "browser_download_open"), String(localized: "browser_share_short"), remove]
                    .allSatisfy { accessibilityElement(labeled: $0, in: window) != nil } && Self.isSettled(window)
            }
            window.saveSnapshot(as: Self.name("long-press", screen))
        }
    }

    private static func element(containing text: String, in view: UIView) -> NSObject? {
        exposedAccessibilityElements(in: view).first { $0.accessibilityLabel?.contains(text) == true }
    }
}
#endif
