#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoodleNotificationSettingsScreenTests {
    private typealias Fixtures = MoodleNotificationFixtures

    @Test("every name fits the iPhone's width and a locked switch is off-limits",
          arguments: [UIUserInterfaceStyle.light, .dark], [false, true])
    func longestNamesFit(style: UIUserInterfaceStyle, chinese: Bool) async throws {
        try await withAccessibilityAutomation {
            let matrix = Fixtures.site(chinese: chinese)
            let settings = MoodleNotificationSettings(
                signIn: testSignIn, api: MoodleNotificationAPI(load: { matrix }, save: { _, _ in })
            )
            settings.method = "email"
            let (window, host) = try Self.show(settings, style: style)
            defer { window.isHidden = true }
            let locked = try #require(matrix.components.flatMap(\.preferences).first { $0.key == Fixtures.lockedKey })
            let longest = chinese ? Fixtures.longestName.zh : Fixtures.longestName.en
            let name = "moodle-notifications-\(chinese ? "zh" : "en")-\(style == .dark ? "dark" : "light")"
            let first = try #require(matrix.components.first?.preferences.first)
            try await waitUntil { accessibilityElement(labeled: first.name, in: host.view) != nil }
            let list = try #require(host.view.descendants(ofType: UICollectionView.self).first)

            var traits: [String: UIAccessibilityTraits] = [:]
            for page in 0..<10 {
                try await Task.sleep(for: .milliseconds(400))
                for label in [locked.name, longest] {
                    if let element = accessibilityElement(labeled: label, in: host.view) { traits[label] = element.accessibilityTraits }
                }
                #expect(list.contentSize.width <= list.bounds.width + 0.5)
                window.saveSnapshot(as: "\(name)-\(page)")
                let end = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
                let next = min(list.contentOffset.y + list.bounds.height * 0.8, end)
                guard next > list.contentOffset.y + 1 else { break }
                list.setContentOffset(CGPoint(x: 0, y: next), animated: false)
            }

            #expect(traits[locked.name]?.contains(.notEnabled) == true)
            #expect(traits[longest]?.contains(.notEnabled) == false)
        }
    }

    @Test("a load failure shows the retry, not an empty list")
    func loadFailureShowsRetry() async throws {
        try await withAccessibilityAutomation {
            let settings = MoodleNotificationSettings(signIn: testSignIn, api: MoodleNotificationAPI(
                load: { throw MoodleWebserviceError.transientNetwork(underlying: "offline") }, save: { _, _ in }
            ))
            let (window, host) = try Self.show(settings, style: .light)
            defer { window.isHidden = true }

            try await waitUntil { accessibilityElement(labeled: String(localized: "action_retry"), in: host.view) != nil }

            #expect(host.view.descendants(ofType: UICollectionView.self).isEmpty)
            window.saveSnapshot(as: "moodle-notifications-load-failure")
        }
    }

    @Test("a sign-out while the page is open goes back")
    func signOutGoesBack() async throws {
        let account = AccountSession()
        let matrix = Fixtures.site(chinese: false)
        let settings = MoodleNotificationSettings(
            signIn: account.signIns.currentSignIn, api: MoodleNotificationAPI(load: { matrix }, save: { _, _ in })
        )
        let pushed = Pushed()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = UIHostingController(rootView: PushedPage(pushed: pushed) {
            MoodleNotificationSettingsView(settings: settings, account: account)
        })
        window.isHidden = false
        defer { window.isHidden = true }
        try await waitUntil { settings.matrix != nil }

        account.endSignIn()

        try await waitUntil { !pushed.isShown }
        #expect(settings.signInEnded)
    }

    @Observable
    final class Pushed {
        var isShown = true
    }

    struct PushedPage<Page: View>: View {
        @Bindable var pushed: Pushed
        @ViewBuilder let page: () -> Page

        var body: some View {
            NavigationStack {
                Color.clear.navigationDestination(isPresented: $pushed.isShown, destination: page)
            }
        }
    }

    private static func show(
        _ settings: MoodleNotificationSettings, style: UIUserInterfaceStyle
    ) throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: NavigationStack {
            MoodleNotificationSettingsView(settings: settings, account: AccountSession())
        })
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }
}
#endif
