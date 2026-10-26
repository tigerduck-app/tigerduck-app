#if os(iOS)
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct StorageSettingsScreenTests {
    private static let moodle = 3_000_000
    private static let mail = 1_000_000

    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func eachRowShowsItsSizeAndDeletesItsOwnKind(style: UIUserInterfaceStyle) async throws {
        try await withAccessibilityAutomation {
            let stores = StorageSettingsTests.Stores([.moodleFiles: Self.moodle, .mail: Self.mail, .websiteData: 0])
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            window.overrideUserInterfaceStyle = style
            let host = UIHostingController(rootView: NavigationStack { StorageSettingsView(cleaner: stores.cleaner) })
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
            }

            let bar = ListFormatter.localizedString(byJoining: [
                "\(StorageKind.moodleFiles.title) \(StorageSizes.text(Self.moodle))",
                "\(StorageKind.mail.title) \(StorageSizes.text(Self.mail))",
            ])
            try await waitUntil { accessibilityElement(labeled: bar, in: host.view) != nil }
            let texts = exposedAccessibilityTexts(in: host.view)
            #expect(texts.contains { $0.contains(StorageSizes.text(Self.moodle + Self.mail)) })
            #expect(try button(.websiteData, in: host).accessibilityTraits.contains(.notEnabled))

            _ = try button(.moodleFiles, in: host).accessibilityActivate()
            // Every button stays off while a delete runs, so the Moodle one alone off means it ended.
            try await waitUntil {
                (try? button(.moodleFiles, in: host).accessibilityTraits.contains(.notEnabled)) == true
                    && (try? button(.mail, in: host).accessibilityTraits.contains(.notEnabled)) == false
            }
            #expect(stores.clears == [.moodleFiles])

            _ = try button(.mail, in: host).accessibilityActivate()
            try await waitUntil { host.presentedViewController is UIAlertController }
            #expect(stores.clears == [.moodleFiles])
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
