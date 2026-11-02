#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// More's root page in the tab bar, with its feature pages wrapped as
/// `swift/TigerDuck/Features/More/MoreView.swift` wraps them.
@MainActor
enum MoreScreen {
    @Observable
    final class Path {
        var value = NavigationPath()
    }

    private struct Root<Settings: View, Feature: View>: View {
        @Bindable var path: Path
        let settings: Settings
        let feature: Feature

        var body: some View {
            TabView(selection: .constant(AppFeature.more)) {
                ForEach(AppFeature.defaultTabs) { tab in
                    Tab(tab.tabBarDisplayName, systemImage: tab.iconName, value: tab) { Color.clear }
                }
                Tab(AppFeature.more.tabBarDisplayName, systemImage: AppFeature.more.iconName, value: .more) {
                    NavigationStack(path: $path.value) {
                        MoreHome(navigationPath: $path.value) { settings }
                            .navigationDestination(for: AppFeature.self) { _ in MoreFeatureDestination { feature } }
                    }
                }
            }
        }
    }

    /// The window, not yet shown: the suite that shows it is listed in `on_screen_tests`.
    static func window(
        path: Path = Path(), width: CGFloat, height: CGFloat, style: UIUserInterfaceStyle = .light,
        textSize: UIContentSizeCategory? = nil, settings: some View, feature: some View
    ) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: height)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: Root(path: path, settings: settings, feature: feature))
        // Set the way the system setting reaches the app, through the window's traits.
        if let textSize { window.traitOverrides.preferredContentSizeCategory = textSize }
        return window
    }

    /// The elements above the feature cards that VoiceOver reaches; the tab bar repeats the heading's
    /// text, and iOS 26 keeps the removed bar title as a transparent label.
    static func top(in window: UIWindow) -> [NSObject] {
        guard let root = window.rootViewController else { return [] }
        return SettingsScreen.elements(in: root).filter { $0.accessibilityFrame.maxY < 160 }
    }

    static func gear(in window: UIWindow) -> NSObject? {
        top(in: window).first {
            $0.accessibilityTraits.contains(.button) && $0.accessibilityFrame.midX > window.bounds.midX
        }
    }

    static func headings(in window: UIWindow) -> [NSObject] {
        top(in: window).filter { $0.accessibilityLabel == String(localized: "feature_more") }
    }
}
#endif
