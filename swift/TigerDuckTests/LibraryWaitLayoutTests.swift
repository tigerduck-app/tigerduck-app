#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// What the Library page shows while it waits after a failed code request
/// (https://github.com/tigerduck-app/tigerduck-app/issues/556).
@MainActor
@Suite(.serialized)
struct LibraryWaitLayoutTests {
    @MainActor
    private final class Taps {
        var count = 0
    }

    private static func show<Content: View>(_ content: Content, width: CGFloat = 375) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 812)
        window.rootViewController = UIHostingController(rootView: content)
        window.isHidden = false
        return window
    }

    @Test("during the wait the card leaves out the countdown, which it shows otherwise", arguments: [false, true])
    func countdownRow(shown: Bool) async throws {
        let countdown = String(format: String(localized: "library_qr_refresh_in_seconds"), 12)
        let title = String(localized: "library_virtual_pass_title")
        try await withAccessibilityAutomation {
            let window = try Self.show(LibraryQRCodeView(
                qrImage: nil, countdown: 12, isLoading: false, username: "B11000000", showsCountdown: shown
            ))
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            try await waitUntil { accessibilityElement(labeled: title, in: root) != nil }

            #expect((accessibilityElement(labeled: countdown, in: root) != nil) == shown)
        }
    }

    @Test("the banner offers Retry during the wait, inside a phone's width with a long message")
    func retryButton() async throws {
        let retry = String(localized: "action_retry")
        let message = String(repeating: "The library server did not answer in time. ", count: 4)
        let taps = Taps()
        try await withAccessibilityAutomation {
            let window = try Self.show(LibraryErrorBanner(message: message, retry: { taps.count += 1 }))
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            try await waitUntil { accessibilityElement(labeled: retry, in: root) != nil }
            let button = try #require(accessibilityElement(labeled: retry, in: root))

            #expect(button.accessibilityFrame.width > 0)
            #expect(button.accessibilityFrame.minX >= 0)
            #expect(button.accessibilityFrame.maxX <= 375)
            #expect(button.accessibilityActivate())
            #expect(taps.count == 1)
        }
    }

    @Test("with nothing to retry, as on the sign-in form, the banner has no Retry")
    func noRetryButton() async throws {
        let retry = String(localized: "action_retry")
        let message = "Wrong password"
        try await withAccessibilityAutomation {
            let window = try Self.show(LibraryErrorBanner(message: message))
            defer { window.isHidden = true }
            let root = try #require(window.rootViewController?.view)
            try await waitUntil { accessibilityElement(labeled: message, in: root) != nil }

            #expect(accessibilityElement(labeled: retry, in: root) == nil)
        }
    }
}
#endif
