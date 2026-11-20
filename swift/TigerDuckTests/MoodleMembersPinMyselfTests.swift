import Defaults
import Foundation
#if os(iOS)
import SwiftUI
import UIKit
#endif
import Testing
@testable import TigerDuck

@MainActor
struct MoodleMembersPinMyselfTests {
    nonisolated static let ownId = 42

    nonisolated static func member(_ id: Int, _ fullName: String, idNumber: String? = nil, role: String = "student") -> MoodleMember {
        MoodleMember(
            id: id, fullName: fullName, idNumber: idNumber, email: nil, groups: [],
            roles: [MoodleMember.Role(shortName: role, name: "", sortOrder: 0)], pictureURL: nil,
            description: "", interests: [], fields: []
        )
    }

    /// The user's student ID sorts between two classmates', so only the pin puts their row first.
    nonisolated static let members = [
        member(5, "Zed Teacher", role: "editingteacher"),
        member(6, "Amy Teacher", role: "editingteacher"),
        member(43, "B11399001 @ Duck One", idNumber: "B11399001"),
        member(ownId, "B11399005 @ Tiger Duck", idNumber: "B11399005"),
        member(44, "B11399009 @ Duck Nine", idNumber: "B11399009"),
    ]

    private static func ids(
        _ query: String = "", pinsMyself: Bool, ownId: Int? = ownId, members: [MoodleMember] = members
    ) -> [[Int]] {
        let content = MoodleMembersView.Content(
            list: MoodleMemberList(ownId: ownId, members: members), isRefreshing: false, failure: nil,
            query: query, pinsMyself: pinsMyself
        )
        guard case .sections(let sections) = content else { return [] }
        return sections.map { $0.members.map(\.id) }
    }

    @Test("on, the user's own row comes first in their section and only there; off, the list keeps its order")
    func ownRowFirst() {
        #expect(Self.ids(pinsMyself: true) == [[6, 5], [42, 43, 44]])
        #expect(Self.ids(pinsMyself: false) == [[6, 5], [43, 42, 44]])
    }

    @Test("a search keeps the user's row first while it matches")
    func search() {
        #expect(Self.ids("duck", pinsMyself: true) == [[42, 43, 44]])
        #expect(Self.ids("duck", pinsMyself: false) == [[43, 42, 44]])
        #expect(Self.ids("nine", pinsMyself: true) == [[44]])
    }

    @Test("with no own id, or one that is not on the list, nothing moves")
    func noOwnRow() {
        #expect(Self.ids(pinsMyself: true, ownId: nil) == [[6, 5], [43, 42, 44]])
        #expect(Self.ids(pinsMyself: true, ownId: 99) == [[6, 5], [43, 42, 44]])
    }

    @Test("a user listed with the assistants comes first among them")
    func assistantFirst() {
        let members = Self.members.map { $0.id == Self.ownId ? Self.member(Self.ownId, "Tiger Duck", role: "teacher") : $0 }
            + [Self.member(7, "Amy Assistant", role: "teacher")]

        #expect(Self.ids(pinsMyself: true, members: members) == [[6, 5], [42, 7], [43, 44]])
        #expect(Self.ids(pinsMyself: false, members: members) == [[6, 5], [7, 42], [43, 44]])
    }

    @Test("the toggle is on by default, and the device keeps the choice under its own key")
    func storedChoice() async {
        #expect(Defaults.Keys.pinMyselfInCourseMembers.defaultValue)
        await withExclusiveRealDefaults {
            defer { Defaults.reset(.pinMyselfInCourseMembers) }
            Defaults[.pinMyselfInCourseMembers] = false
            #expect(UserDefaults.standard.object(forKey: "pinMyselfInCourseMembers") as? Bool == false)
            Defaults.reset(.pinMyselfInCourseMembers)
            #expect(Defaults[.pinMyselfInCourseMembers])
        }
    }

    @Test("the toggle is a Moodle page setting, which a Settings search finds")
    func foundBySettingsSearch() {
        #expect(SettingsRow.pinMyself.place == .page(.moodle))
        let result = SettingsSearch.results(for: SettingsRow.pinMyself.label, in: SettingsState()).first { $0.row == .pinMyself }
        #expect(result?.path == [String(localized: PageSettings.moodle.titleKey), SettingsRow.pinMyself.label])
    }
}

#if os(iOS)
@MainActor
@Suite(.serialized)
struct MoodleMembersPinMyselfScreenTests {
    typealias Menu = PageMenuScreenTests

    private static func store(root: URL) -> MoodleCourseStore {
        let cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        let list = MoodleMemberList(ownId: MoodleMembersPinMyselfTests.ownId, members: MoodleMembersPinMyselfTests.members)
        return MoodleCourseStore(
            courseId: 1, termCourseIds: [1],
            context: MoodleCacheContext(account: "B11399005", cache: cache.moodle, signIn: testSignIn, now: { Date() }),
            api: MoodleCourseAPI(
                functions: { [MoodleCourseMembersService.membersFunction] },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                members: { _ in list }
            )
        )
    }

    /// One tap per window: a closed menu's items stay in the window's accessibility tree, so the
    /// second open of `PageMenuScreenTests.openMenu` would find no new item.
    @Test("the members screen's ⋯ has the toggle, which shows its state and reorders the open list at once",
          arguments: [Menu.Look.all[0], Menu.Look.all[2]], [true, false])
    func theMenuTogglesThePin(look: Menu.Look, startsOn: Bool) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                Defaults[.pinMyselfInCourseMembers] = startsOn
                defer { Defaults.reset(.pinMyselfInCourseMembers) }
                let root = FileManager.default.temporaryDirectory
                    .appendingPathComponent("MoodleMembersPinMyselfScreenTests-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: root) }
                let store = Self.store(root: root)
                await store.refreshMembers()
                let preferences = AppPreferences()
                // Tall enough that the largest text size scrolls nothing.
                let (window, _) = try SettingsScreen.show(
                    MoodleMembersView(store: store, policy: VisualStylePolicy(preset: .default)) { _ in },
                    state: SettingsScreen.allOpenButSchool(preferences), preferences: preferences,
                    width: Menu.narrowestPhoneWidth, height: 1200, style: look.style
                )
                window.traitOverrides.preferredContentSizeCategory = look.size
                window.makeKey()
                defer { window.isHidden = true }

                let me = "Tiger Duck, \(String(localized: "course_member_me"))"
                @MainActor func myRowLeads() -> Bool? {
                    guard let mine = accessibilityElement(labeled: me, in: window),
                          let classmate = accessibilityElement(labeled: "Duck One", in: window) else { return nil }
                    return mine.accessibilityFrame.minY < classmate.accessibilityFrame.minY
                }
                let name = "\(startsOn ? "on" : "off")-\(look.name)-\(Menu.language)"
                try await waitUntil { myRowLeads() == startsOn }
                try await Task.sleep(for: .milliseconds(400))
                window.saveSnapshot(as: "members-pin-myself-list-\(name)")

                let items = try await Menu.openMenu(labeled: String(localized: "action_more_actions"), in: window)
                #expect(items.compactMap(\.accessibilityLabel) == [SettingsRow.pinMyself.label, String(localized: "action_settings")])
                let toggle = try #require(items.first)
                #expect(toggle.accessibilityTraits.contains(.button))
                #expect(toggle.accessibilityTraits.contains(.selected) == startsOn)
                for item in items {
                    #expect(item.accessibilityFrame.maxX <= window.frame.maxX + 0.5)
                }
                window.saveSnapshot(as: "members-pin-myself-menu-\(name)")

                try await Menu.tap(toggle, in: window)
                try await waitUntil { Defaults[.pinMyselfInCourseMembers] == !startsOn }
                try await waitUntil { myRowLeads() == !startsOn }
                try await Task.sleep(for: .milliseconds(600))
                window.saveSnapshot(as: "members-pin-myself-tapped-\(name)")
            }
        }
    }
}
#endif
