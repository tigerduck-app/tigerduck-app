#if os(iOS)
import SwiftUI
import Testing
import TigerDuckCore
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct AccentGradientScreenTests {
    private typealias Screen = SettingsScreen

    struct Look: CustomTestStringConvertible {
        let name: String
        let style: UIUserInterfaceStyle
        let size: UIContentSizeCategory?

        var testDescription: String { name }
        var height: CGFloat { size == nil ? 812 : 2000 }

        static let all = [
            Look(name: "light", style: .light, size: nil),
            Look(name: "dark", style: .dark, size: nil),
            Look(name: "light-largest", style: .light, size: .accessibilityExtraExtraExtraLarge),
            Look(name: "dark-largest", style: .dark, size: .accessibilityExtraExtraExtraLarge),
        ]
    }

    enum Editing: String, CaseIterable, CustomTestStringConvertible {
        case oneStop, linear, radial, angular, mesh

        var testDescription: String { rawValue }

        var accent: AccentGradient {
            guard let style = AccentGradient.Style(rawValue: rawValue) else { return AccentGradient(color: 0x4B48D1) }
            return AccentGradient(stops: [0x4B48D1, 0x9442C7, 0xD61F45], style: style)!
        }
    }

    private static let keys = ["accentColorHex", "accentGradient"]

    private static func withAccent(_ accent: AccentGradient, _ body: (AppPreferences) async throws -> Void) async throws {
        try await withExclusiveRealDefaults {
            let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
            defer {
                for (key, value) in zip(keys, saved) {
                    if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
                }
            }
            let preferences = AppPreferences()
            preferences.accent = accent
            try await body(preferences)
        }
    }

    private static func window(_ view: some View, look: Look) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: look.height)
        window.overrideUserInterfaceStyle = look.style
        window.rootViewController = UIHostingController(rootView: view)
        if let size = look.size { window.traitOverrides.preferredContentSizeCategory = size }
        window.isHidden = false
        return window
    }

    private static func save(_ window: UIWindow, as name: String, look: Look) {
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        window.saveSnapshot(as: "accent-\(name)-\(look.name)-\(language)")
    }

    private static func label(_ key: LocalizedStringResource) -> String {
        String(localized: key)
    }

    @Test("the accent row with a gradient saved, its switch beside it", arguments: Look.all)
    func settingsRow(look: Look) async throws {
        try await withAccessibilityAutomation {
            try await Self.withAccent(Editing.linear.accent) { preferences in
                let view = SettingsList(sheets: SettingsSheetState())
                let (window, host) = try Screen.show(
                    view.tint(preferences.accentStyle), state: Screen.allOpenButSchool(preferences),
                    preferences: preferences, width: 375, height: look.height, style: look.style
                )
                defer { window.isHidden = true }
                if let size = look.size { window.traitOverrides.preferredContentSizeCategory = size }
                try await waitUntil { Screen.shows(SettingsRow.accentGradientOnDevices.label, in: host) }
                let custom = try #require(accessibilityElement(labeled: Self.label("settings_accent_gradient_custom"), in: host.view))
                #expect(custom.accessibilityTraits.contains(.selected))
                let blue = try #require(accessibilityElement(labeled: Self.label("color_name_blue"), in: host.view))
                #expect(!blue.accessibilityTraits.contains(.selected))
                Self.save(window, as: "settings", look: look)
            }
        }
    }

    @Test("the editor shows the style and direction only for a gradient", arguments: Editing.allCases, Look.all)
    func editor(editing: Editing, look: Look) async throws {
        try await withAccessibilityAutomation {
            try await Self.withAccent(editing.accent) { preferences in
                let window = try Self.window(AccentGradientEditor(preferences: preferences).tint(preferences.accentStyle), look: look)
                defer { window.isHidden = true }
                let accent = editing.accent
                let stops = (1...accent.stops.count).map {
                    String(format: Self.label("a11y_accent_gradient_stop"), $0)
                }
                try await waitUntil { stops.allSatisfy { accessibilityElement(labeled: $0, in: window) != nil } }

                for style in AccentGradient.Style.allCases {
                    let button = accessibilityElement(labeled: Self.label(style.titleKey), in: window)
                    #expect((button != nil) == accent.isGradient, "\(style)")
                    #expect((button?.accessibilityTraits.contains(.selected) ?? false) == (accent.isGradient && style == accent.style))
                }
                for direction in AccentGradient.Direction.allCases {
                    let button = accessibilityElement(labeled: Self.label(direction.titleKey), in: window)
                    #expect((button != nil) == (accent.isGradient && accent.style == .linear), "\(direction)")
                }
                #expect(accessibilityElement(labeled: Self.label("action_add"), in: window) != nil)
                Self.save(window, as: "editor-\(editing.rawValue)", look: look)
            }
        }
    }

    @Test("More draws its feature icons in the gradient", arguments: Look.all)
    func more(look: Look) async throws {
        try await withAccessibilityAutomation {
            try await Self.withAccent(Editing.linear.accent) { preferences in
                let window = try MoreScreen.window(
                    width: 375, height: 812, style: look.style, textSize: look.size, tint: preferences.accentStyle,
                    settings: EmptyView(), feature: EmptyView()
                )
                window.makeKeyAndVisible()
                defer { window.isHidden = true }
                try await waitUntil { MoreScreen.gear(in: window) != nil }
                Self.save(window, as: "more", look: look)
            }
        }
    }
}
#endif
