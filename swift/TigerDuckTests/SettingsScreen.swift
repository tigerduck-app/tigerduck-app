#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// Shows a Settings view as the app would, with the state and preferences the app would set.
@MainActor
enum SettingsScreen {
    /// Every gate closed, every row but the library sign-out and the What's New row shown.
    static let closed = SettingsState(hasFlipToLibrary: true, hasSchoolMail: true)

    /// Every row shown except the school sign-in's, whose pages need an app behind them.
    static func reachable(_ preferences: AppPreferences) -> SettingsState {
        SettingsState(
            library: .init(isSignedIn: true, name: "B11000000"), mail: .init(isSignedIn: true, name: "B11000000"),
            isCloudSyncOn: true, usesEnglishClassroomNames: preferences.useEnglishClassroomAbbreviation,
            hasFlipToLibrary: true, hasSchoolMail: true, hasWhatsNew: true
        )
    }

    static func show(
        _ view: some View, state: SettingsState, preferences: AppPreferences? = nil,
        width: CGFloat = 402, height: CGFloat = 2400, style: UIUserInterfaceStyle = .light
    ) throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: NavigationStack { view }
            .environment(\.settingsState, state)
            .environment(preferences ?? AppPreferences()))
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }

    static func texts(in host: UIViewController) -> [String] {
        exposedAccessibilityTexts(in: host.view)
    }

    static func shows(_ text: String, in host: UIViewController) -> Bool {
        texts(in: host).contains { $0.contains(text) }
    }

    /// The row's element: the one carrying the gate's reason as its hint when the gate is closed.
    static func element(of row: SettingsRow, hint: String?, in host: UIViewController) -> NSObject? {
        let elements = exposedAccessibilityElements(in: host.view)
        let hinted = elements.filter { hint == nil || $0.accessibilityHint == hint }
        return hinted.first { ($0.accessibilityLabel ?? "").contains(row.label) } ?? (hint == nil ? nil : hinted.first)
    }

    /// A row that opens something, such as a page row on the Settings root, rather than its text.
    static func link(labeled label: String, in host: UIViewController) -> NSObject? {
        exposedAccessibilityElements(in: host.view).first {
            $0.accessibilityLabel == label && $0.accessibilityTraits.contains(.button)
        }
    }

    static func navigation(in controller: UIViewController) -> UINavigationController? {
        if let navigation = controller as? UINavigationController { return navigation }
        return controller.children.lazy.compactMap { navigation(in: $0) }.first
    }

    static func depth(in host: UIViewController) -> Int {
        navigation(in: host)?.viewControllers.count ?? 0
    }

    static func open(_ page: PageSettings, from host: UIViewController) async throws {
        let label = String(localized: page.titleKey)
        try await waitUntil { link(labeled: label, in: host) != nil }
        _ = try #require(link(labeled: label, in: host)).accessibilityActivate()
        try await waitUntil { depth(in: host) == 2 }
    }
}
#endif
