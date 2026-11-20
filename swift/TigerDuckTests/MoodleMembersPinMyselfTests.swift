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

    private nonisolated static let members = [
        MoodleMembersPinMyselfTests.member(5, "Zed Teacher", role: "editingteacher"),
        MoodleMembersPinMyselfTests.member(6, "Amy Teacher", role: "editingteacher"),
        MoodleMembersPinMyselfTests.member(43, "B11399001 @ Duck One", idNumber: "B11399001"),
        MoodleMembersPinMyselfTests.member(44, "B11399002 @ Duck Two", idNumber: "B11399002"),
        MoodleMembersPinMyselfTests.member(MoodleMembersPinMyselfTests.ownId, "B11399009 @ Tiger Duck", idNumber: "B11399009"),
    ]

    private static let me = "Tiger Duck, \(String(localized: "course_member_me"))"

    private static func store(root: URL) -> MoodleCourseStore {
        let cache = TestCache(
            cacheDir: root.appendingPathComponent("cache", isDirectory: true),
            persistentDir: root.appendingPathComponent("persistent", isDirectory: true)
        )
        let list = MoodleMemberList(ownId: MoodleMembersPinMyselfTests.ownId, members: members)
        return MoodleCourseStore(
            courseId: 1, termCourseIds: [1],
            context: MoodleCacheContext(account: "B11399009", cache: cache.moodle, signIn: testSignIn, now: { Date() }),
            api: MoodleCourseAPI(
                functions: { [MoodleCourseMembersService.membersFunction] },
                forums: { _ in [] },
                discussions: { _, _ in [] },
                markViewed: { _, _ in },
                members: { _ in list }
            )
        )
    }

    private static func showList(look: Menu.Look, pinsMyself: Bool, root: URL) async throws -> UIWindow {
        Defaults[.pinMyselfInCourseMembers] = pinsMyself
        let store = store(root: root)
        await store.refreshMembers()
        let preferences = AppPreferences()
        let (window, _) = try SettingsScreen.show(
            MoodleMembersView(store: store, policy: VisualStylePolicy(preset: .default)) { _ in },
            state: SettingsScreen.allOpenButSchool(preferences), preferences: preferences,
            width: Menu.narrowestPhoneWidth, height: 1200, style: look.style
        )
        window.traitOverrides.preferredContentSizeCategory = look.size
        window.makeKey()
        try await waitUntil { myRowLeads(in: window) == pinsMyself }
        try await Task.sleep(for: .milliseconds(400))
        return window
    }

    private static func myRowLeads(in window: UIWindow) -> Bool? {
        guard let mine = accessibilityElement(labeled: me, in: window),
              let classmate = accessibilityElement(labeled: "Duck One", in: window) else { return nil }
        return mine.accessibilityFrame.minY < classmate.accessibilityFrame.minY
    }

    private static func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MoodleMembersPinMyselfScreenTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// A closed menu's items stay in the window's accessibility tree, where a second open would
    /// take them for the page's own.
    @Test("the members screen's ⋯ has the toggle, which shows its state and reorders the open list at once",
          arguments: [Menu.Look.all[0], Menu.Look.all[1], Menu.Look.all[2]], [true, false])
    func theMenuTogglesThePin(look: Menu.Look, startsOn: Bool) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                defer { Defaults.reset(.pinMyselfInCourseMembers) }
                let root = Self.temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let window = try await Self.showList(look: look, pinsMyself: startsOn, root: root)
                defer { window.isHidden = true }
                let name = "\(startsOn ? "on" : "off")-\(look.name)-\(Menu.language)"
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
                try await waitUntil { Self.myRowLeads(in: window) == !startsOn }
                try await Task.sleep(for: .milliseconds(600))
                window.saveSnapshot(as: "members-pin-myself-tapped-\(name)")
            }
        }
    }

    /// After rows move, a List sizes a row that stayed only a frame later, and whether a picture
    /// lands in that frame varies from run to run.
    @Test("a row that moves to or from the end of its section is spaced as the settled list from the first frame",
          arguments: [Menu.Look.all[0], Menu.Look.all[2]])
    func theMovedRowsSpacingHolds(look: Menu.Look) async throws {
        try await withExclusiveRealDefaults {
            try await withAccessibilityAutomation {
                defer { Defaults.reset(.pinMyselfInCourseMembers) }
                let root = Self.temporaryRoot()
                defer { try? FileManager.default.removeItem(at: root) }
                let window = try await Self.showList(look: look, pinsMyself: true, root: root)
                defer { window.isHidden = true }
                let name = "\(look.name)-\(Menu.language)"
                func pixels(_ picture: UIImage) -> Data? { picture.cgImage?.dataProvider?.data as Data? }
                @MainActor func move(pinsMyself: Bool) async throws {
                    Defaults[.pinMyselfInCourseMembers] = pinsMyself
                    try await waitUntil { Self.myRowLeads(in: window) == pinsMyself }
                }

                // On a busy runner a screen that just appeared can still be settling.
                for pinsMyself in [false, true] {
                    try await move(pinsMyself: pinsMyself)
                    try await Task.sleep(for: .seconds(1))
                }
                for step in 1...6 {
                    try await move(pinsMyself: step.isMultiple(of: 2))
                    var frames: [UIImage] = []
                    for _ in 0..<10 {
                        frames.append(window.picture())
                        try await Task.sleep(for: .milliseconds(50))
                    }
                    try await Task.sleep(for: .seconds(1))
                    let settled = window.picture()
                    for (index, frame) in frames.enumerated() where pixels(frame) != pixels(settled) {
                        frame.saveSnapshot(as: "members-pin-myself-moved-\(step)-\(index)-\(name)")
                        settled.saveSnapshot(as: "members-pin-myself-moved-\(step)-settled-\(name)")
                        Issue.record("frame \(index) after move \(step) differs from the list it settles on")
                    }
                }
                window.saveSnapshot(as: "members-pin-myself-moved-\(name)")
            }
        }
    }
}
#endif
