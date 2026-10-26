#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct TigerSyncLinksSectionTests {
    private final class Opened {
        var urls: [URL] = []
    }

    @Test func aLinkToTheWebsiteOpensInTheSystemBrowser() async throws {
        try await withAccessibilityAutomation {
            let opened = Opened()
            let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 390, height: 844)
            let host = UIHostingController(rootView: Form { TigerSyncLinksSection() }
                .linkRouting()
                .environment(\.openURL, OpenURLAction { url in
                    opened.urls.append(url)
                    return .handled
                }))
            window.rootViewController = host
            window.makeKeyAndVisible()
            defer {
                host.dismiss(animated: false)
                window.isHidden = true
            }

            let label = String(localized: "onboarding_privacy_policy_label")
            try await waitUntil { accessibilityElement(labeled: label, in: host.view) != nil }
            _ = try #require(accessibilityElement(labeled: label, in: host.view)).accessibilityActivate()

            try await waitUntil(timeout: .seconds(10)) { !opened.urls.isEmpty }
            #expect(opened.urls == [AppURLs.privacyPolicy])
            #expect(host.presentedViewController == nil)
        }
    }
}
#endif
