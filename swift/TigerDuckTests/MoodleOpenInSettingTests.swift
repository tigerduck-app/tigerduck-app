#if os(iOS)
import Defaults
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct MoodleOpenInSettingTests {
    private typealias Screen = SettingsScreen
    typealias Menus = PageMenuScreenTests

    private static var row: String { SettingsRow.moodleOpenIn.label }
    private static var choices: [String] {
        [String(localized: "settings_moodle_open_in_app"), String(localized: "settings_browser_in_app")]
    }

    private static func rowShows(_ choice: String, in host: UIViewController) -> Bool {
        Screen.texts(in: host).contains { $0.contains(row) && $0.contains(choice) }
    }

    private static func show(hasMoodleApp: Bool, look: Menus.Look) throws -> (UIWindow, UIViewController) {
        let preferences = AppPreferences()
        var state = Screen.allOpenButSchool(preferences)
        state.hasMoodleApp = hasMoodleApp
        let (window, host) = try Screen.show(
            PageSettings.moodle.view, state: state, preferences: preferences,
            width: Menus.narrowestPhoneWidth, height: 812, style: look.style
        )
        window.traitOverrides.preferredContentSizeCategory = look.size
        window.makeKey()
        return (window, host)
    }

    @Test("with the Moodle app, Open Moodle in shows the choice, and its menu changes it", arguments: Menus.Look.all)
    func theMenuChangesTheChoice(look: Menus.Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                Defaults.reset(.moodleOpenTarget)
                defer { Defaults.reset(.moodleOpenTarget) }
                let (window, host) = try Self.show(hasMoodleApp: true, look: look)
                defer { window.isHidden = true }
                try await waitUntil { Self.rowShows(Self.choices[0], in: host) }
                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: "moodle-open-in-\(look.name)-\(Menus.language)")

                // The menu opens from the value, which shares its label with the menu's own item.
                let items = try await Menus.openMenu(in: window) {
                    accessibilityElement(labeled: Self.choices[0], in: window) ?? Screen.element(of: .moodleOpenIn, hint: nil, in: host)
                }
                let chosen = exposedAccessibilityElements(in: window).filter { $0.accessibilityLabel == Self.choices[0] }
                #expect(items.compactMap(\.accessibilityLabel) == [Self.choices[1]])
                #expect(chosen.contains { $0.accessibilityTraits.contains(.selected) })
                #expect(items.allSatisfy { $0.accessibilityFrame.maxX <= window.frame.maxX + 0.5 })
                window.saveSnapshot(as: "moodle-open-in-menu-\(look.name)-\(Menus.language)")

                try await Menus.tap(try #require(items.first), in: window)
                try await waitUntil { Defaults[.moodleOpenTarget] == .browser }
                try await waitUntil { Self.rowShows(Self.choices[1], in: host) }
            }
        }
    }

    @Test("without the Moodle app, the Moodle page has no Open Moodle in", arguments: [Menus.Look.all[0]])
    func noRowWithoutTheApp(look: Menus.Look) async throws {
        try await withAccessibilityAutomation {
            let (window, host) = try Self.show(hasMoodleApp: false, look: look)
            defer { window.isHidden = true }
            try await waitUntil { Screen.shows(SettingsRow.moodleNotifications.label, in: host) }
            #expect(!Screen.shows(Self.row, in: host))
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "moodle-open-in-no-app-\(look.name)-\(Menus.language)")
        }
    }
}
#endif
