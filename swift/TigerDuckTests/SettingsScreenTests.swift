#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct SettingsScreenTests {
    private typealias Screen = SettingsScreen

    @Test("a closed gate leaves its row disabled, and a tap shows why and changes nothing",
          arguments: SettingsRow.allCases.filter { $0.gate != nil }, [false, true])
    func aClosedGateShowsWhy(row: SettingsRow, fromSettings: Bool) async throws {
        try await withAccessibilityAutomation {
            guard case .page(let page) = row.place else { throw GateOutsideAPage() }
            let preferences = AppPreferences()
            let flip = preferences.flipToLibraryEnabled
            let view = fromSettings ? AnyView(SettingsList(sheets: SettingsSheetState())) : AnyView(page.view)
            let (window, host) = try Screen.show(view, state: Screen.closed, preferences: preferences)
            defer { window.isHidden = true }
            if fromSettings { try await Screen.open(page, from: host) }
            let reason = String(localized: try #require(row.closedReason(in: Screen.closed)))
            try await waitUntil { Screen.element(of: row, hint: reason, in: host) != nil }
            let depth = Screen.depth(in: host)
            let element = try #require(Screen.element(of: row, hint: reason, in: host))

            #expect(element.accessibilityHint == reason)
            _ = element.accessibilityActivate()

            try await waitUntil { accessibilityElement(labeled: reason, in: host.view) != nil }
            #expect(Screen.depth(in: host) == depth)
            #expect(preferences.flipToLibraryEnabled == flip)
        }
    }

    @Test("from Settings, a page reads the state Settings has")
    func aPageFromSettingsSeesAnOpenGate() async throws {
        try await withAccessibilityAutomation {
            let state = SettingsState(isCloudSyncOn: true)
            let (window, host) = try Screen.show(SettingsList(sheets: SettingsSheetState()), state: state)
            defer { window.isHidden = true }
            try await Screen.open(.home, from: host)
            try await waitUntil { Screen.element(of: .assignmentReminders, hint: nil, in: host) != nil }

            let row = try #require(Screen.element(of: .assignmentReminders, hint: nil, in: host))
            #expect(!row.accessibilityTraits.contains(.notEnabled))
            #expect(row.accessibilityHint == nil)
        }
    }

    @Test("every row a page lists in this state is on that page", arguments: PageSettings.allCases)
    func everyRowOfAPageIsOnIt(page: PageSettings) async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            let state = Screen.reachable(preferences)
            let (window, host) = try Screen.show(page.view, state: state, preferences: preferences)
            defer { window.isHidden = true }
            let rows = page.rows.filter { $0.isShown(in: state) }
            try await waitUntil { rows.allSatisfy { Screen.shows($0.label, in: host) } }
        }
    }

    @Test("every row of the Settings root and every page is on it")
    func everyRootRowIsOnSettings() async throws {
        try await withAccessibilityAutomation {
            let state = Screen.reachable(AppPreferences())
            let (window, host) = try Screen.show(SettingsList(sheets: SettingsSheetState()), state: state, height: 4000)
            defer { window.isHidden = true }
            let rows = SettingsRow.allCases.filter { row in
                if case .section = row.place { return row.isShown(in: state) }
                return false
            }
            let pages = PageSettings.allCases.map { String(localized: $0.titleKey) }
            try await waitUntil {
                rows.allSatisfy { Screen.shows($0.label, in: host) } && pages.allSatisfy { Screen.link(labeled: $0, in: host) != nil }
            }
        }
    }

    @Test("a row its condition hides is not on its page")
    func hiddenRowsAreNotOnTheirPage() async throws {
        try await withAccessibilityAutomation {
            var state = Screen.closed
            state.isChineseUI = true
            state.hasFlipToLibrary = false
            state.library.isSignedIn = true
            for (page, hidden, shown) in [(PageSettings.classTable, SettingsRow.englishCourseNames, SettingsRow.showClassroom),
                                          (.library, .flipToLibrary, .librarySignOut)] {
                let (window, host) = try Screen.show(page.view, state: state)
                defer { window.isHidden = true }
                try await waitUntil { Screen.shows(shown.label, in: host) }
                #expect(!Screen.shows(hidden.label, in: host))
            }
        }
    }

    @Test("a search result opens the page that holds the row", arguments: PageSettings.allCases)
    func aResultOpensItsPage(page: PageSettings) async throws {
        try await withAccessibilityAutomation {
            let state = Screen.closed
            let row = try #require(page.rows.first { $0.isShown(in: state) })
            let result = try #require(SettingsSearch.results(for: row.label, in: state).first { $0.row == row })
            let list = SettingsList(sheets: SettingsSheetState(), query: row.label)
            let (window, host) = try Screen.show(list, state: state)
            defer { window.isHidden = true }
            try await waitUntil { Screen.link(labeled: result.text, in: host) != nil }

            _ = try #require(Screen.link(labeled: result.text, in: host)).accessibilityActivate()

            try await waitUntil { Screen.depth(in: host) == 2 }
            let title = Screen.navigation(in: host)?.topViewController?.navigationItem.title
            #expect(title == String(localized: page.titleKey))
        }
    }

    @Test("a result on the Settings root closes the search and shows the row in place")
    func aRootResultShowsTheRoot() async throws {
        try await withAccessibilityAutomation {
            let state = Screen.closed
            let row = SettingsRow.accentColor
            let result = try #require(SettingsSearch.results(for: row.label, in: state).first { $0.row == row })
            let (window, host) = try Screen.show(SettingsList(sheets: SettingsSheetState(), query: row.label), state: state)
            defer { window.isHidden = true }
            try await waitUntil { Screen.link(labeled: result.text, in: host) != nil }

            _ = try #require(Screen.link(labeled: result.text, in: host)).accessibilityActivate()

            try await waitUntil { Screen.shows(SettingsRow.tigerSync.label, in: host) }
            #expect(Screen.depth(in: host) == 1)
        }
    }

    private struct GateOutsideAPage: Error {}
}
#endif
