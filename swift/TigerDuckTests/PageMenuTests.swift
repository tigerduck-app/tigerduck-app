#if os(iOS)
import Defaults
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
struct PageMenuToggleTests {
    private final class Box {
        var isOn: Bool
        var turnedOn = 0

        init(isOn: Bool) { self.isOn = isOn }

        var binding: Binding<Bool> { Binding(get: { self.isOn }, set: { self.isOn = $0 }) }
    }

    @Test("turning a switch on runs its settings page's step for that, such as asking to notify")
    func turningOnRunsTheSettingsPagesStep() {
        let box = Box(isOn: false)
        let toggle = PageMenuToggle.turningOn(box.binding) { box.turnedOn += 1 }

        toggle.wrappedValue = true
        #expect(box.isOn)
        #expect(box.turnedOn == 1)
        toggle.wrappedValue = false
        #expect(!box.isOn)
        #expect(box.turnedOn == 1)
    }
}

/// Opens each page's ⋯ with a finger, as `SettingsScreenTests` taps a closed row.
@MainActor
@Suite(.serialized)
struct PageMenuScreenTests {
    private typealias Screen = SettingsScreen

    enum Page: String, CaseIterable, CustomTestStringConvertible {
        case home, bulletins, mail, library, moodle

        var testDescription: String { rawValue }

        var settings: PageSettings {
            switch self {
            case .home: .home
            case .bulletins: .bulletins
            case .mail: .mail
            case .library: .library
            case .moodle: .moodle
            }
        }

        /// Bulletins has a setting to change only while signed in to school.
        @MainActor func state(_ preferences: AppPreferences) -> SettingsState {
            var state = Screen.allOpenButSchool(preferences)
            if self == .bulletins { state.school.isSignedIn = true }
            return state
        }

        var menuLabel: String {
            self == .home ? String(localized: "home_more_actions") : String(localized: "action_more_actions")
        }

        /// The ⋯'s items in order, in `state(_:)`.
        var items: [String] {
            let settings = String(localized: "action_settings")
            return switch self {
            case .home:
                [String(localized: "home_edit")]
                    + [SettingsRow.showFullDueDate, .invertSlider, .assignmentReminders, .liveActivity].map(\.label) + [settings]
            case .bulletins, .moodle: [settings]
            case .mail: [SettingsRow.mailNotifications.label, settings]
            case .library: [SettingsRow.flipToLibrary.label, settings, SettingsRow.librarySignOut.label]
            }
        }
    }

    struct Look: CustomTestStringConvertible {
        let name: String
        let style: UIUserInterfaceStyle
        let size: UIContentSizeCategory

        var testDescription: String { name }

        static let all = [
            Look(name: "light", style: .light, size: .large),
            Look(name: "dark", style: .dark, size: .large),
            Look(name: "light-largest", style: .light, size: .accessibilityExtraExtraExtraLarge),
            Look(name: "dark-largest", style: .dark, size: .accessibilityExtraExtraExtraLarge),
        ]
    }

    @MainActor
    @Observable
    final class Filter {
        var unreadOnly = false
    }

    /// What a page's header needs, made once per test so a redraw keeps it.
    @MainActor
    struct Fixtures {
        let reminders = LiveActivityPreferencesStore()
        let readState = BulletinReadStateStore()
        let mail = MailListViewModelTests.harness(inboxCount: 6).model
        let filter = Filter()
        var unreadShown: [Int] = []
    }

    static let narrowestPhoneWidth: CGFloat = 375

    @ViewBuilder
    static func header(of page: Page, _ fixtures: Fixtures) -> some View {
        switch page {
        case .home:
            VStack { HomeTitleBar(reminders: fixtures.reminders) {}; Spacer() }
                .pageMenu(.home)
        case .bulletins:
            List {}
                .toolbar {
                    BulletinsToolbar(
                        unreadOnly: Bindable(fixtures.filter).unreadOnly, unreadShown: fixtures.unreadShown,
                        readState: fixtures.readState, bulletinsSyncedAt: nil
                    )
                }
                .pageMenu(.bulletins)
        case .mail:
            VStack { MailTitleBar(viewModel: fixtures.mail, isLoggedIn: true); Spacer() }
                .pageMenu(.mail)
        case .library:
            VStack {
                HStack { Spacer(); PageMenuButton(page: .library) { LibraryMenuItems() } }.padding()
                Spacer()
            }
            .pageMenu(.library)
        case .moodle:
            Color.clear.moodleListChrome(title: "Moodle", page: .course(1), refresh: {})
        }
    }

    private static func show(
        _ view: some View, state: SettingsState, preferences: AppPreferences, look: Look = Look.all[0]
    ) throws -> (UIWindow, UIViewController) {
        let (window, host) = try Screen.show(
            view, state: state, preferences: preferences, width: narrowestPhoneWidth, height: 812, style: look.style
        )
        window.traitOverrides.preferredContentSizeCategory = look.size
        window.makeKey()
        return (window, host)
    }

    static func tap(_ element: NSObject, in window: UIWindow, holding: Duration = .milliseconds(50)) async throws {
        let frame = element.accessibilityFrame
        let point = window.convert(CGPoint(x: frame.midX, y: frame.midY), from: window.screen.coordinateSpace)
        try await fingerTap(at: point, in: window, holding: holding)
    }

    /// The menu's items in order: the buttons that were not on the page before it opened. The menu
    /// lists its items twice, and the first copy ends at the first repeat.
    static func items(in window: UIWindow, besides page: Set<String>) -> [NSObject] {
        var seen = Set<String>()
        var items: [NSObject] = []
        for element in exposedAccessibilityElements(in: window) where element.accessibilityTraits.contains(.button) {
            guard let label = element.accessibilityLabel, !page.contains(label) else { continue }
            guard seen.insert(label).inserted else { break }
            items.append(element)
        }
        return items
    }

    /// A filter says whether it is on, and VoiceOver finds its mark-all-read among its actions.
    static func expectFilter(labeled label: String, selected: Bool, offers markAllRead: String, in window: UIWindow) throws {
        let filter = try #require(accessibilityElement(labeled: label, in: window))
        #expect(filter.accessibilityTraits.contains(.selected) == selected)
        #expect(filter.accessibilityCustomActions?.contains { $0.name == markAllRead } == true)
    }

    /// Whether `condition` holds within `timeout`, recording nothing when it does not.
    static func holds(within timeout: Duration, _ condition: () -> Bool) async throws -> Bool {
        let end = ContinuousClock.now + timeout
        while ContinuousClock.now < end {
            if condition() { return true }
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// `tries` above one taps again when the menu does not open: on iOS 26.5 a new window's first
    /// touch can go nowhere after another test's window presented a sheet.
    static func openMenu(
        labeled label: String, in window: UIWindow, holding: Duration = .milliseconds(50), tries: Int = 3
    ) async throws -> [NSObject] {
        try await waitUntil { accessibilityElement(labeled: label, in: window) != nil }
        let page = Set(exposedAccessibilityElements(in: window).compactMap(\.accessibilityLabel))
        for _ in 0..<tries {
            try await tap(try #require(accessibilityElement(labeled: label, in: window)), in: window, holding: holding)
            if try await holds(within: .seconds(5), { !items(in: window, besides: page).isEmpty }) { break }
        }
        try await waitUntil { !items(in: window, besides: page).isEmpty }
        // The items arrive together; the wait lets the menu finish growing for a picture.
        try await Task.sleep(for: .milliseconds(600))
        return items(in: window, besides: page)
    }

    /// Signed in, the bulletins settings view needs the app, so its sheet is left out.
    @Test("each page's ⋯ lists its items, and Settings opens that page's settings",
          arguments: Page.allCases.filter { $0 != .bulletins })
    func settingsOpensThePage(page: Page) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let preferences = AppPreferences()
                let state = page.state(preferences)
                let (window, host) = try Self.show(Self.header(of: page, Fixtures()), state: state, preferences: preferences)
                defer { window.isHidden = true }

                let items = try await Self.openMenu(labeled: page.menuLabel, in: window)
                #expect(items.compactMap(\.accessibilityLabel) == page.items)

                let settings = try #require(items.first { $0.accessibilityLabel == String(localized: "action_settings") })
                try await Self.tap(settings, in: window)
                let first = try #require(page.settings.rows.first { $0.isShown(in: state) })
                try await waitUntil { Self.sheet(over: host).map { Screen.shows(first.label, in: $0) } == true }
                #expect(Self.sheet(over: host).map {
                    Screen.shows(String(localized: page.settings.titleKey), in: $0)
                        && Screen.shows(String(localized: "action_done"), in: $0)
                } == true)
                try await Task.sleep(for: .milliseconds(600))
                window.saveSnapshot(as: "page-menu-\(page)-sheet-\(Self.language)")

                // Done closes the sheet, and the page's ⋯ opens again on the first tap.
                let done = try #require(Self.sheet(over: host).flatMap {
                    accessibilityElement(labeled: String(localized: "action_done"), in: $0.view)
                })
                try await Self.tap(done, in: window)
                try await waitUntil { Self.sheet(over: host) == nil }
                #expect(try await Self.openMenu(labeled: page.menuLabel, in: window, tries: 1).count == page.items.count)
            }
        }
    }

    @Test("the bulletins ⋯ shows only while signed in to school")
    func bulletinsMenuNeedsTheSchoolSignIn() async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            for signedIn in [false, true] {
                let state = signedIn ? Page.bulletins.state(preferences) : Screen.allOpenButSchool(preferences)
                let (window, _) = try Self.show(Self.header(of: .bulletins, Fixtures()), state: state, preferences: preferences)
                defer { window.isHidden = true }
                try await waitUntil { accessibilityElement(labeled: String(localized: "bulletin_show_unread_only_action"), in: window) != nil }
                if signedIn {
                    let items = try await Self.openMenu(labeled: Page.bulletins.menuLabel, in: window)
                    #expect(items.compactMap(\.accessibilityLabel) == Page.bulletins.items)
                } else {
                    #expect(accessibilityElement(labeled: Page.bulletins.menuLabel, in: window) == nil)
                }
            }
        }
    }

    @Test("the class table's settings sit right above its reset, in the same section")
    func classTableSettingsSitAboveTheReset() async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            let menu = VStack {
                HStack {
                    Spacer()
                    HeaderMenuButton(accessibilityLabel: String(localized: "class_table_more_actions")) {
                        ClassTableResetSection {}
                    }
                }
                .padding()
                Spacer()
            }
            let (window, _) = try Self.show(menu, state: Screen.allOpenButSchool(preferences), preferences: preferences)
            defer { window.isHidden = true }

            let items = try await Self.openMenu(labeled: String(localized: "class_table_more_actions"), in: window)
            #expect(items.compactMap(\.accessibilityLabel) == [
                String(localized: "action_settings"), String(localized: "class_table_reset_title"),
            ])
        }
    }

    @Test("with TigerSync off, Home's ⋯ dims its reminder switches, says why under each, and they change nothing")
    func closedSwitchesSayWhy() async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let saved = (Defaults[.isAssignmentReminderEnabled], Defaults[.isLiveActivityEnabled])
                defer { (Defaults[.isAssignmentReminderEnabled], Defaults[.isLiveActivityEnabled]) = saved }
                let fixtures = Fixtures()
                let before = (fixtures.reminders.isAssignmentReminderEnabled, fixtures.reminders.isLiveActivityEnabled)
                let (window, _) = try Self.show(Self.header(of: .home, fixtures), state: Screen.closed, preferences: AppPreferences())
                defer { window.isHidden = true }

                let items = try await Self.openMenu(labeled: Page.home.menuLabel, in: window)
                for row in [SettingsRow.assignmentReminders, .liveActivity] {
                    let reason = String(localized: try #require(row.closedReason(in: Screen.closed)))
                    let item = try #require(items.first { $0.accessibilityLabel?.hasPrefix(row.label) == true })
                    #expect(item.accessibilityTraits.contains(.notEnabled))
                    #expect([item.accessibilityLabel, item.accessibilityValue].compactMap(\.self).joined().contains(reason))
                }
                window.saveSnapshot(as: "page-menu-home-tigersync-off-\(Self.language)")

                let item = try #require(items.first { $0.accessibilityLabel?.hasPrefix(SettingsRow.assignmentReminders.label) == true })
                try await Self.tap(item, in: window)
                try await Task.sleep(for: .milliseconds(500))
                #expect(fixtures.reminders.isAssignmentReminderEnabled == before.0)
                #expect(fixtures.reminders.isLiveActivityEnabled == before.1)
            }
        }
    }

    @Test("a closed row in the settings sheet shows its reason in the sheet")
    func aClosedRowInTheSheetShowsWhyThere() async throws {
        try await withAccessibilityAutomation {
            let row = SettingsRow.assignmentReminders
            let (window, host) = try Self.show(Self.header(of: .home, Fixtures()), state: Screen.closed, preferences: AppPreferences())
            defer { window.isHidden = true }
            let reason = String(localized: try #require(row.closedReason(in: Screen.closed)))

            let items = try await Self.openMenu(labeled: Page.home.menuLabel, in: window)
            try await Self.tap(try #require(items.first { $0.accessibilityLabel == String(localized: "action_settings") }), in: window)
            try await waitUntil { Self.sheet(over: host).flatMap { Screen.element(of: row, hint: reason, in: $0) } != nil }
            // The sheet slides up, and a tap during that misses the row.
            try await Task.sleep(for: .milliseconds(800))
            let sheet = try #require(Self.sheet(over: host))
            let element = try #require(Screen.element(of: row, hint: reason, in: sheet))
            #expect(accessibilityElement(labeled: reason, in: sheet.view) == nil)

            let point = window.convert(element.accessibilityActivationPoint, from: window.screen.coordinateSpace)
            try await fingerTap(at: point, in: window)
            let inSheet = try await Self.holds(within: .seconds(3)) { accessibilityElement(labeled: reason, in: sheet.view) != nil }
            #expect(inSheet, "over the page instead: \(accessibilityElement(labeled: reason, in: host.view) != nil)")
        }
    }

    @Test("a tap on the bulletins filter shows unread only, and its long press marks every shown bulletin read")
    func bulletinsFilter() async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let saved = Defaults[.bulletinReadIds]
                defer { Defaults[.bulletinReadIds] = saved }
                Defaults[.bulletinReadIds] = []
                var fixtures = Fixtures()
                fixtures.unreadShown = [-3, -2, -1]
                let (window, _) = try Self.show(
                    Self.header(of: .bulletins, fixtures), state: Screen.closed, preferences: AppPreferences()
                )
                defer { window.isHidden = true }

                let unreadOnly = String(localized: "bulletin_show_unread_only_action")
                try await waitUntil { accessibilityElement(labeled: unreadOnly, in: window) != nil }
                try Self.expectFilter(labeled: unreadOnly, selected: false,
                                      offers: String(localized: "bulletin_mark_all_read_action"), in: window)
                try await Self.tap(try #require(accessibilityElement(labeled: unreadOnly, in: window)), in: window)
                try await waitUntil { fixtures.filter.unreadOnly }
                try await waitUntil { accessibilityElement(labeled: unreadOnly, in: window)?.accessibilityTraits.contains(.selected) == true }

                let items = try await Self.openMenu(labeled: unreadOnly, in: window, holding: .seconds(1))
                #expect(fixtures.filter.unreadOnly)
                let markAll = try #require(items.first {
                    $0.accessibilityLabel == String(localized: "bulletin_mark_all_read_action")
                })
                try await Self.tap(markAll, in: window)
                try await waitUntil { fixtures.unreadShown.allSatisfy(fixtures.readState.isRead) }
                #expect(fixtures.filter.unreadOnly)
            }
        }
    }

    @Test("a tap on the mail filter shows unread only, and its long press marks every shown message read")
    func mailFilter() async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let fixtures = Fixtures()
                await fixtures.mail.load()
                let (window, _) = try Self.show(
                    Self.header(of: .mail, fixtures), state: Screen.allOpenButSchool(AppPreferences()),
                    preferences: AppPreferences()
                )
                defer { window.isHidden = true }

                let filter = String(localized: "school_mail_unread_only")
                try await waitUntil { accessibilityElement(labeled: filter, in: window) != nil }
                try Self.expectFilter(labeled: filter, selected: false,
                                      offers: String(localized: "school_mail_mark_all_read"), in: window)
                try await Self.tap(try #require(accessibilityElement(labeled: filter, in: window)), in: window)
                try await waitUntil { fixtures.mail.unreadOnly }
                try await waitUntil { accessibilityElement(labeled: filter, in: window)?.accessibilityTraits.contains(.selected) == true }
                #expect(fixtures.mail.displayedRows.count == 3)

                let items = try await Self.openMenu(labeled: filter, in: window, holding: .seconds(1))
                let markAll = try #require(items.first {
                    $0.accessibilityLabel == String(localized: "school_mail_mark_all_read")
                })
                try await Self.tap(markAll, in: window)
                try await waitUntil { fixtures.mail.rows.allSatisfy(\.summary.isSeen) }
                #expect(fixtures.mail.unreadOnly)
            }
        }
    }

    @Test("the browser's More sheet ends with Settings, which opens the browser's settings")
    func browserMoreSheet() async throws {
        try await withAccessibilityAutomation {
            let preferences = AppPreferences()
            let state = Screen.allOpenButSchool(preferences)
            let more = ScrollView {
                BrowserMenu(page: BrowserPage(), showsNavigation: false) { $0() }
            }
            .pageMenu(.browser)
            let (window, host) = try Self.show(more, state: state, preferences: preferences)
            defer { window.isHidden = true }

            let label = String(localized: "action_settings")
            @MainActor func buttons() -> [NSObject] {
                exposedAccessibilityElements(in: window).filter { $0.accessibilityTraits.contains(.button) }
            }
            @MainActor func settingsCard() -> NSObject? {
                exposedAccessibilityElements(in: window).first { $0.accessibilityLabel?.contains(label) == true }
            }
            try await waitUntil { settingsCard() != nil }
            let row = try #require(settingsCard())
            #expect(buttons().allSatisfy { $0.accessibilityFrame.minY <= row.accessibilityFrame.minY })
            try await Task.sleep(for: .milliseconds(400))
            window.saveSnapshot(as: "page-menu-browser-more-\(Self.language)")

            try await Self.tap(row, in: window)
            try await waitUntil { Self.sheet(over: host).map { Screen.shows(SettingsRow.addressBar.label, in: $0) } == true }
        }
    }

    @Test("each page's ⋯, open at 375 points", arguments: Page.allCases, Look.all)
    func openMenuPicture(page: Page, look: Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                let preferences = AppPreferences()
                let (window, _) = try Self.show(
                    Self.header(of: page, Fixtures()), state: page.state(preferences), preferences: preferences, look: look
                )
                defer { window.isHidden = true }
                try await waitUntil { accessibilityElement(labeled: page.menuLabel, in: window) != nil }
                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: "page-menu-\(page)-\(look.name)-closed-\(Self.language)")

                let items = try await Self.openMenu(labeled: page.menuLabel, in: window)
                #expect(items.count == page.items.count)
                for item in items {
                    #expect(item.accessibilityFrame.maxX <= window.frame.maxX + 0.5)
                }
                window.saveSnapshot(as: "page-menu-\(page)-\(look.name)-\(Self.language)")
            }
        }
    }

    static var language: String { Bundle.main.preferredLocalizations.first ?? "en" }

    /// The topmost controller presented over `controller` or one of its children.
    static func sheet(over controller: UIViewController) -> UIViewController? {
        guard let presented = controller.presentedViewController
            ?? controller.children.lazy.compactMap({ sheet(over: $0) }).first else { return nil }
        return sheet(over: presented) ?? presented
    }
}
#endif
