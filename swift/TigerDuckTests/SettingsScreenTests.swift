#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct SettingsScreenTests {
    private typealias Screen = SettingsScreen

    @Test("a closed gate leaves its row a dimmed control with the reason as its hint, and changes nothing",
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

            #expect(element.accessibilityTraits.contains(.notEnabled))
            switch row {
            case .flipToLibrary:
                #expect(element.accessibilityTraits.contains(.toggleButton))
                #expect(element.accessibilityValue != nil)
            case .mailDisplayName:
                #expect(element is UITextField)
            default:
                #expect(element.accessibilityTraits.contains(.button))
            }
            // Refused, so VoiceOver taps the activation point, which the row's tap catcher covers.
            #expect(!element.accessibilityActivate())
            #expect(element.accessibilityFrame.contains(element.accessibilityActivationPoint))

            try await Task.sleep(for: .milliseconds(300))
            #expect(Screen.depth(in: host) == depth)
            #expect(preferences.flipToLibraryEnabled == flip)
        }
    }

    @Test("a finger's tap on a closed row shows the reason and leaves the control as it was",
          arguments: [SettingsRow.flipToLibrary, .assignmentReminders])
    func aTapOnAClosedRowShowsWhy(row: SettingsRow) async throws {
        try await withAccessibilityAutomation {
            guard case .page(let page) = row.place else { throw GateOutsideAPage() }
            let preferences = AppPreferences()
            let flip = preferences.flipToLibraryEnabled
            let (window, host) = try Screen.show(page.view, state: Screen.closed, preferences: preferences, height: 874)
            defer { window.isHidden = true }
            let reason = String(localized: try #require(row.closedReason(in: Screen.closed)))
            try await waitUntil { Screen.element(of: row, hint: reason, in: host) != nil }
            let element = try #require(Screen.element(of: row, hint: reason, in: host))
            let value = element.accessibilityValue
            let depth = Screen.depth(in: host)
            #expect(accessibilityElement(labeled: reason, in: host.view) == nil)

            let point = window.convert(element.accessibilityActivationPoint, from: window.screen.coordinateSpace)
            try await fingerTap(at: point, in: window)

            try await waitUntil { accessibilityElement(labeled: reason, in: host.view) != nil }
            #expect(Screen.element(of: row, hint: reason, in: host)?.accessibilityValue == value)
            #expect(preferences.flipToLibraryEnabled == flip)
            #expect(Screen.depth(in: host) == depth)
        }
    }

    @Test("a toast shows its message over the page and goes away")
    func aToastShowsAndGoesAway() async throws {
        try await withAccessibilityAutomation {
            let reason = String(localized: SettingsGate.tigerSync.reasonKey)
            let page = ZStack { PageSettings.home.view; Screen.ShowsToast(message: SettingsGate.tigerSync.reasonKey) }
            let (window, host) = try Screen.show(page.toastHost(), state: Screen.closed)
            defer { window.isHidden = true }

            try await waitUntil { accessibilityElement(labeled: reason, in: host.view) != nil }
            try await waitUntil(timeout: .seconds(10)) { accessibilityElement(labeled: reason, in: host.view) == nil }
        }
    }

    @Test("a gate that changes while its page is on screen disables or enables the row",
          arguments: [SettingsRow.assignmentReminders, .moodleNotifications, .mailNotifications, .flipToLibrary])
    func aGateChangeReachesTheOpenPage(row: SettingsRow) async throws {
        try await withAccessibilityAutomation {
            guard case .page(let page) = row.place, let gate = row.gate else { throw GateOutsideAPage() }
            let open = SettingsState(
                school: .init(isSignedIn: true), library: .init(isSignedIn: true), mail: .init(isSignedIn: true),
                isCloudSyncOn: true, hasFlipToLibrary: true, hasSchoolMail: true
            )
            let live = Screen.LiveState(open)
            let (window, host) = try Screen.show(page.view, live: live)
            defer { window.isHidden = true }
            let reason = String(localized: gate.reasonKey)
            @MainActor func hint() -> String? { Screen.element(of: row, hint: nil, in: host)?.accessibilityHint }
            try await waitUntil { Screen.element(of: row, hint: nil, in: host) != nil }
            #expect(hint() != reason)

            live.state = Self.closing(gate, in: open)
            try await waitUntil { hint() == reason }

            live.state = open
            try await waitUntil { Screen.element(of: row, hint: nil, in: host) != nil && hint() != reason }
        }
    }

    @Test("a page left with no row goes back")
    func anEmptyPageGoesBack() async throws {
        try await withAccessibilityAutomation {
            let live = Screen.LiveState(SettingsState(library: .init(isSignedIn: true)))
            let page = PageSettings.library
            let root = List { NavigationLink(String(localized: page.titleKey)) { page.view } }
            let (window, host) = try Screen.show(root, live: live)
            defer { window.isHidden = true }
            try await Screen.open(page, from: host)
            try await waitUntil { Screen.shows(SettingsRow.librarySignOut.label, in: host) }

            live.state.library.isSignedIn = false

            try await waitUntil { Screen.depth(in: host) == 1 }
        }
    }

    private static func closing(_ gate: SettingsGate, in state: SettingsState) -> SettingsState {
        var closed = state
        switch gate {
        case .tigerSync: closed.isCloudSyncOn = false
        case .schoolSignIn: closed.school.isSignedIn = false
        case .mailSignIn: closed.mail.isSignedIn = false
        case .librarySignIn: closed.library.isSignedIn = false
        }
        return closed
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
            let state = Screen.allOpenButSchool(preferences)
            let (window, host) = try Screen.show(page.view, state: state, preferences: preferences)
            defer { window.isHidden = true }
            let rows = page.rows.filter { $0.isShown(in: state) }
            try await waitUntil { rows.allSatisfy { Screen.shows($0.label, in: host) } }
        }
    }

    @Test("every row of the Settings root and every page is on it")
    func everyRootRowIsOnSettings() async throws {
        try await withAccessibilityAutomation {
            let state = Screen.allOpenButSchool(AppPreferences())
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
                                          (.library, .flipToLibrary, .librarySignOut),
                                          (.moodle, .moodleOpenIn, .moodleNotifications)] {
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
            let row = SettingsRow.apiEndpoint
            let result = try #require(SettingsSearch.results(for: row.label, in: state).first { $0.row == row })
            let list = SettingsList(sheets: SettingsSheetState(), query: row.label)
            let (window, host) = try Screen.show(list, state: state, height: 874)
            defer { window.isHidden = true }
            try await waitUntil { Screen.link(labeled: result.text, in: host) != nil }

            _ = try #require(Screen.link(labeled: result.text, in: host)).accessibilityActivate()

            try await waitUntil {
                Screen.elements(in: host).contains { element in
                    let frame = element.accessibilityFrame
                    return element.accessibilityLabel == row.label && window.bounds.contains(CGPoint(x: frame.midX, y: frame.midY))
                }
            }
            #expect(Screen.depth(in: host) == 1)
        }
    }

    private struct GateOutsideAPage: Error {}
}

#endif
