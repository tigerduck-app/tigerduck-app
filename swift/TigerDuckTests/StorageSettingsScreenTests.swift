#if os(iOS)
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct StorageSettingsScreenTests {
    typealias Screen = TLSPinPromptTests.Screen

    private static let sizes: [StorageKind: Int] = [
        .moodleFiles: 734_000_000, .moodleData: 2_400_000, .mailAttachments: 18_600_000, .mailCache: 104_900_000,
        .mail: 186_200_000, .browserDownloads: 0, .websiteData: 45_700_000,
    ]

    private static func show(_ stores: StorageSettingsTests.Stores, screen: Screen) throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: screen.width, height: screen.height)
        window.overrideUserInterfaceStyle = screen.style
        if let textSize = screen.textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
        let host = UIHostingController(rootView: NavigationStack { StorageSettingsView(cleaner: stores.cleaner) })
        window.rootViewController = host
        window.makeKeyAndVisible()
        return (window, host)
    }

    private static var bar: String {
        ListFormatter.localizedString(byJoining: StorageKind.allCases.compactMap { kind in
            guard let size = sizes[kind], size > 0 else { return nil }
            return "\(kind.title) \(StorageSizes.text(size))"
        })
    }

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func eachRowShowsItsSizeAndDeletesItsOwnKind(style: UIUserInterfaceStyle) async throws {
        try await withAccessibilityAutomation {
            let stores = StorageSettingsTests.Stores(Self.sizes)
            let (window, host) = try Self.show(stores, screen: Screen(style: style, width: 390, textSize: nil))
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
            }

            try await waitUntil { accessibilityElement(labeled: Self.bar, in: host.view) != nil }
            let texts = exposedAccessibilityTexts(in: host.view)
            #expect(texts.contains { $0.contains(StorageSizes.text(Self.sizes.values.reduce(0, +))) })
            #expect(try button(.browserDownloads, in: host).accessibilityTraits.contains(.notEnabled))

            _ = try button(.moodleFiles, in: host).accessibilityActivate()
            // Every button stays off while a delete runs, so the Moodle one alone off means it ended.
            try await waitUntil {
                (try? button(.moodleFiles, in: host).accessibilityTraits.contains(.notEnabled)) == true
                    && (try? button(.moodleData, in: host).accessibilityTraits.contains(.notEnabled)) == false
            }
            #expect(stores.clears == [.moodleFiles])

            _ = try button(.mail, in: host).accessibilityActivate()
            try await waitUntil { host.presentedViewController is UIAlertController }
            #expect(stores.clears == [.moodleFiles])
        }
    }

    @Test("every row at 375 points, light and dark, with the largest text too", arguments: Screen.all.filter { $0.width == 375 })
    func picture(screen: Screen) async throws {
        try await withAccessibilityAutomation {
            let stores = StorageSettingsTests.Stores(Self.sizes)
            let (window, host) = try Self.show(stores, screen: screen)
            defer { window.isHidden = true }
            try await waitUntil { accessibilityElement(labeled: Self.bar, in: host.view) != nil }
            let list = try #require(host.view.descendants(ofType: UICollectionView.self).first)
            for part in 0..<4 {
                try await Task.sleep(for: .milliseconds(400))
                #expect(list.contentSize.width <= list.bounds.width + 0.5)
                window.saveSnapshot(as: "storage-\(screen.name)-\(part)-\(PageMenuScreenTests.language)")
                let end = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
                let next = min(list.contentOffset.y + list.bounds.height * 0.8, end)
                guard next > list.contentOffset.y + 1 else { break }
                list.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }
            for kind in StorageKind.allCases {
                #expect(exposedAccessibilityTexts(in: host.view).contains(kind.title) || (try? button(kind, in: host)) != nil, "\(kind)")
            }
        }
    }

    @Test func webKitKeepsAStoreInTheFolderItsSizeIsReadFrom() async throws {
        let id = UUID()
        let folder = BrowserData.storeFolder(id)
        try await Self.withPage(inStore: id) {
            try await waitUntil(timeout: .seconds(30)) { (BrowserData.storeBytes(in: folder, inUse: true) ?? 0) > 0 }
        }
        try? await WKWebsiteDataStore.remove(forIdentifier: id)
        try? FileManager.default.removeItem(at: folder)
    }

    private static func withPage(inStore id: UUID, _ body: () async throws -> Void) async throws {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: id)
        let page = WKWebView(frame: CGRect(x: 0, y: 0, width: 100, height: 100), configuration: configuration)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.addSubview(page)
        window.isHidden = false
        defer { window.isHidden = true }
        page.loadHTMLString("<script>localStorage.setItem('k', 'v')</script>", baseURL: URL(string: "https://storage.example/"))
        try await body()
    }

    private func button(_ kind: StorageKind, in host: UIViewController) throws -> NSObject {
        let label = String(format: String(localized: "settings_storage_delete_kind"), kind.title)
        return try #require(accessibilityElement(labeled: label, in: host.view))
    }
}
#endif
