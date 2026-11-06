#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
enum SettingsScreen {
    static let closed = SettingsState(hasFlipToLibrary: true, hasSchoolMail: true)

    static func allOpenButSchool(_ preferences: AppPreferences) -> SettingsState {
        SettingsState(
            library: .init(isSignedIn: true, name: "B11000000"), mail: .init(isSignedIn: true, name: "B11000000"),
            isCloudSyncOn: true, usesEnglishClassroomNames: preferences.useEnglishClassroomAbbreviation,
            hasFlipToLibrary: true, hasSchoolMail: true, hasWhatsNew: true, hasMoodleApp: true
        )
    }

    struct ShowsToast: View {
        let message: LocalizedStringResource
        @Environment(\.showToast) private var showToast

        var body: some View {
            Color.clear.frame(width: 1, height: 1).task { showToast(message) }
        }
    }

    @Observable
    final class LiveState {
        var state: SettingsState

        init(_ state: SettingsState) {
            self.state = state
        }
    }

    private struct Live<Content: View>: View {
        let live: LiveState
        let content: Content

        var body: some View {
            content.environment(\.settingsState, live.state)
        }
    }

    static func show(
        _ view: some View, state: SettingsState, preferences: AppPreferences? = nil,
        width: CGFloat = 402, height: CGFloat = 2400, style: UIUserInterfaceStyle = .light
    ) throws -> (UIWindow, UIViewController) {
        try show(view, live: LiveState(state), preferences: preferences, width: width, height: height, style: style)
    }

    static func show(
        _ view: some View, live: LiveState, preferences: AppPreferences? = nil,
        width: CGFloat = 402, height: CGFloat = 2400, style: UIUserInterfaceStyle = .light
    ) throws -> (UIWindow, UIViewController) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        let host = UIHostingController(rootView: Live(live: live, content: NavigationStack { view })
            .environment(preferences ?? AppPreferences()))
        window.rootViewController = host
        window.isHidden = false
        return (window, host)
    }

    /// A node's elements and its subviews can overlap, so each object is walked once. A list keeps
    /// cells it took off screen as hidden subviews, which VoiceOver skips and so does this.
    static func elements(in host: UIViewController) -> [NSObject] {
        var seen = Set<ObjectIdentifier>()
        func walk(_ node: NSObject) -> [NSObject] {
            guard seen.insert(ObjectIdentifier(node)).inserted, !node.accessibilityElementsHidden else { return [] }
            if let view = node as? UIView, view.isHidden || view.alpha == 0 { return [] }
            return (node.isAccessibilityElement ? [node] : []) + accessibilityChildren(of: node).flatMap(walk)
        }
        return walk(host.view)
    }

    static func texts(in host: UIViewController) -> [String] {
        elements(in: host).map { node in
            [node.accessibilityLabel, node.accessibilityValue].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: ", ")
        }
    }

    static func shows(_ text: String, in host: UIViewController) -> Bool {
        texts(in: host).contains { $0.contains(text) }
    }

    static func element(of row: SettingsRow, hint: String?, in host: UIViewController) -> NSObject? {
        let hinted = elements(in: host).filter { hint == nil || $0.accessibilityHint == hint }
        let named = hinted.first { element in
            [element.accessibilityLabel, element.accessibilityValue].contains { $0?.contains(row.label) == true }
        }
        return named ?? (hint == nil ? nil : hinted.first)
    }

    static func link(labeled label: String, in host: UIViewController) -> NSObject? {
        elements(in: host).first {
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
