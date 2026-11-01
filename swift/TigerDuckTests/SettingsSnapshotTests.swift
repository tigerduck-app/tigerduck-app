#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

/// Pictures of Settings for a person to look at, kept when the checkout has a `.out` folder, and
/// a check that no screen is wider than the phone.
@MainActor
@Suite(.serialized)
struct SettingsSnapshotTests {
    private typealias Screen = SettingsScreen
    /// An iPhone 18 Pro, and the narrowest phone the app supports.
    static let widths: [CGFloat] = [402, 375]

    private static func state(_ preferences: AppPreferences) -> SettingsState {
        var state = Screen.reachable(preferences)
        state.school = .init(isSignedIn: false)
        state.isChineseUI = Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        return state
    }

    @Test("the Settings root", arguments: widths)
    func root(width: CGFloat) async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            let (window, host) = try Screen.show(
                SettingsList(sheets: SettingsSheetState()), state: Self.state(preferences),
                preferences: preferences, width: width, height: 874
            )
            defer { window.isHidden = true }
            try await waitUntil { Screen.shows(SettingsRow.accentColor.label, in: host) }
            try await Self.saveEveryScreen(of: window, as: "root-\(Int(width))")
        }
    }

    @Test("each page's settings", arguments: PageSettings.allCases, widths)
    func page(page: PageSettings, width: CGFloat) async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            let state = Self.state(preferences)
            let (window, host) = try Screen.show(page.view, state: state, preferences: preferences, width: width, height: 874)
            defer { window.isHidden = true }
            let first = try #require(page.rows.first { $0.isShown(in: state) })
            try await waitUntil { Screen.shows(first.label, in: host) }
            try await Self.saveEveryScreen(of: window, as: "page-\(page)-\(Int(width))")
        }
    }

    @Test("a search with results", arguments: widths)
    func search(width: CGFloat) async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            let state = Self.state(preferences)
            let query = String(localized: "settings_section_notifications")
            let results = SettingsSearch.results(for: query, in: state)
            #expect(!results.isEmpty)
            let list = SettingsList(sheets: SettingsSheetState(), query: query)
            let (window, host) = try Screen.show(list, state: state, preferences: preferences, width: width, height: 874)
            defer { window.isHidden = true }
            try await waitUntil { results.allSatisfy { Screen.shows($0.text, in: host) } }
            try await Self.saveEveryScreen(of: window, as: "search-\(Int(width))")
        }
    }

    @Test("the toast a closed gate shows", arguments: widths)
    func toast(width: CGFloat) async throws {
        try await withAccessibilityAutomation {
            let state = Screen.closed
            let (window, host) = try Screen.show(PageSettings.home.view, state: state, width: width, height: 874)
            defer { window.isHidden = true }
            let reason = String(localized: SettingsGate.tigerSync.reasonKey)
            try await waitUntil { Screen.element(of: .liveActivity, hint: reason, in: host) != nil }
            _ = Screen.element(of: .liveActivity, hint: reason, in: host)?.accessibilityActivate()
            try await waitUntil { accessibilityElement(labeled: reason, in: host.view) != nil }
            try await Task.sleep(for: .milliseconds(400))
            Self.save(window, as: "toast-\(Int(width))")
        }
    }

    /// Saves the window once per screenful while scrolling its list down, and checks that the
    /// list never scrolls sideways.
    private static func saveEveryScreen(of window: UIWindow, as name: String) async throws {
        let list = try #require(window.rootViewController?.view.descendants(ofType: UICollectionView.self).first)
        for screen in 0..<6 {
            try await Task.sleep(for: .milliseconds(400))
            #expect(list.contentSize.width <= list.bounds.width + 0.5, "\(name) is wider than the phone")
            save(window, as: "\(name)-\(screen)")
            let end = list.contentSize.height + list.adjustedContentInset.bottom - list.bounds.height
            let next = min(list.contentOffset.y + list.bounds.height * 0.8, end)
            guard next > list.contentOffset.y + 1 else { break }
            list.setContentOffset(CGPoint(x: 0, y: next), animated: false)
        }
    }

    private static func save(_ window: UIWindow, as name: String, file: String = #filePath) {
        let out = URL(filePath: file).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: ".out/settings-by-page")
        // CI's checkout has no `.out` folder, so only a local run keeps the picture.
        guard FileManager.default.fileExists(atPath: out.deletingLastPathComponent().path(percentEncoded: false)) else { return }
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        try? image.pngData()?.write(to: out.appending(path: "\(name)-\(language).png"))
    }
}
#endif
