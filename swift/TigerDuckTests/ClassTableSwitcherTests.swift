#if os(iOS)
import SwiftUI
import Testing
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct ClassTableSwitcherTests {
    private final class Folder {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClassTableSwitcherTests-\(UUID().uuidString)", isDirectory: true)
        var file: URL { url.appendingPathComponent("imported_class_tables.json") }
        deinit { try? FileManager.default.removeItem(at: url) }
    }

    private struct People {
        let store: ImportedClassTableStore
        let ming: ImportedPerson
        let hua: ImportedPerson
    }

    private final class Count {
        var value = 0
    }

    private static func code(_ studentId: String) -> ClassTableShareCode {
        ClassTableShareCode(
            format: .tigerDuck, studentId: studentId, sharedAt: nil,
            terms: [ClassTableShareCode.Term(semester: "1151", courseNos: ["CS1010001"])]
        )
    }

    private static func people(_ folder: Folder) throws -> People {
        let store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })
        let ming = try #require(store.add(code("B11300001"), nickname: "Ming", courses: [:], for: testSignIn))
        let hua = try #require(store.add(code("B11300002"), nickname: "Hua", courses: [:], for: testSignIn))
        return People(store: store, ming: ming, hua: hua)
    }

    @Test("the switcher lists import first, then the user followed by the rotation in its order")
    func rowsInOrder() throws {
        let people = try Self.people(Folder())
        people.store.show(people.hua.id)

        #expect(ClassTableSwitcherEntry.sections(in: people.store, userName: "B11300000") == [
            [.importClassTable],
            [
                .user(name: "B11300000", isShown: false),
                .person(id: people.ming.id, nickname: "Ming", isShown: false),
                .person(id: people.hua.id, nickname: "Hua", isShown: true),
            ],
        ])
    }

    @Test("the long-press people follow as a group, and Other last as a submenu, each only with someone in it",
          arguments: [ImportedPerson.Placement.longPressMenu, .other])
    func longPressAndOtherSections(placement: ImportedPerson.Placement) throws {
        let people = try Self.people(Folder())
        let wei = try #require(people.store.add(Self.code("B11300003"), nickname: "Wei", courses: [:], for: testSignIn))
        people.store.move(people.ming.id, to: placement, before: nil, for: testSignIn)
        people.store.show(people.ming.id)

        let ming = ClassTableSwitcherEntry.person(id: people.ming.id, nickname: "Ming", isShown: true)
        let rest: [ClassTableSwitcherEntry] = [
            .user(name: "B11300000", isShown: false),
            .person(id: people.hua.id, nickname: "Hua", isShown: false),
            .person(id: wei.id, nickname: "Wei", isShown: false),
        ]
        #expect(ClassTableSwitcherEntry.sections(in: people.store, userName: "B11300000") == [
            [.importClassTable], rest, placement == .other ? [.others([ming])] : [ming],
        ])

        people.store.move(wei.id, to: placement == .other ? .longPressMenu : .other, before: nil, for: testSignIn)
        let wei2 = ClassTableSwitcherEntry.person(id: wei.id, nickname: "Wei", isShown: false)
        #expect(ClassTableSwitcherEntry.sections(in: people.store, userName: "B11300000") == [
            [.importClassTable], Array(rest.prefix(2)), placement == .other ? [wei2] : [ming], [.others([placement == .other ? ming : wei2])],
        ])
        #expect(ClassTableSwitcherEntry.others([ming]).title == String(localized: "class_table_list_section_other"))
    }

    @Test("with nobody imported the switcher offers the import and the user's own class table")
    func rowsWithoutPeople() {
        let folder = Folder()
        let store = ImportedClassTableStore(fileURL: folder.file, signedInStudentId: { "B11300000" })

        #expect(ClassTableSwitcherEntry.sections(in: store, userName: "B11300000") == [
            [.importClassTable],
            [.user(name: "B11300000", isShown: true)],
        ])
    }

    @Test("the user's row shows the student ID, and Not signed in without one")
    func userRowName() {
        #expect(ClassTableSwitcherEntry.userName(studentId: "B11300000") == "B11300000")
        #expect(ClassTableSwitcherEntry.userName(studentId: nil) == String(localized: "common_not_signed_in"))
        #expect(ClassTableSwitcherEntry.userName(studentId: "") == String(localized: "common_not_signed_in"))
    }

    @Test("a person's row and the user's row show that class table, and the import row asks for the import flow")
    func choosingARow() throws {
        let people = try Self.people(Folder())
        let importRequests = Count()
        let requestImport = { importRequests.value += 1 }

        ClassTableSwitcherEntry.person(id: people.hua.id, nickname: "Hua", isShown: false)
            .choose(in: people.store, requestImport: requestImport)
        #expect(people.store.shownPersonID == people.hua.id)
        ClassTableSwitcherEntry.user(name: "B11300000", isShown: false)
            .choose(in: people.store, requestImport: requestImport)
        #expect(people.store.shownPersonID == nil)
        #expect(importRequests.value == 0)
        ClassTableSwitcherEntry.importClassTable.choose(in: people.store, requestImport: requestImport)
        #expect(importRequests.value == 1)
        #expect(people.store.shownPersonID == nil)
    }

    @Test("the tab bar's menu keeps Add class table farthest from the tab, and Other's people in their order",
          arguments: [true, false])
    func tabMenuOrder(opensUpward: Bool) throws {
        let people = try Self.people(Folder())
        let wei = try #require(people.store.add(Self.code("B11300003"), nickname: "Wei", courses: [:], for: testSignIn))
        let lin = try #require(people.store.add(Self.code("B11300004"), nickname: "Lin", courses: [:], for: testSignIn))
        people.store.move(people.hua.id, to: .longPressMenu, before: nil, for: testSignIn)
        people.store.move(wei.id, to: .other, before: nil, for: testSignIn)
        people.store.move(lin.id, to: .other, before: nil, for: testSignIn)
        people.store.show(lin.id)
        var chosen: [String] = []

        let menu = ClassTableTabBarHandler.menu(
            ClassTableSwitcherEntry.sections(in: people.store, userName: "B11300000"),
            opensUpward: opensUpward
        ) { chosen.append($0.title) }

        let sections = menu.children.compactMap { $0 as? UIMenu }
        let titles = sections.map { $0.children.map(\.title) }
        let other = String(localized: "class_table_list_section_other")
        let expected = [[String(localized: "class_table_import")], ["B11300000", "Ming"], ["Hua"], [other]]
        #expect(titles == (opensUpward ? expected : expected.reversed().map { $0.reversed() }))
        #expect(sections.count == menu.children.count)
        #expect(sections.allSatisfy { $0.options.contains(.displayInline) })
        let submenu = try #require(sections.flatMap(\.children).compactMap { $0 as? UIMenu }.first)
        #expect(!submenu.options.contains(.displayInline))
        let others = submenu.children.compactMap { $0 as? UIAction }
        #expect(others.map(\.title) == ["Wei", "Lin"])
        #expect(others.filter { $0.state == .on }.map(\.title) == ["Lin"])
        let actions = sections.flatMap(\.children).compactMap { $0 as? UIAction }
        #expect(actions.filter { $0.state == .on }.isEmpty)

        others.first?.performWithSender(nil, target: nil)
        #expect(chosen == ["Wei"])
    }

    private struct Tabs: View {
        let store: ImportedClassTableStore
        @State private var selection = 1

        var body: some View {
            TabView(selection: $selection) {
                Tab("Home", systemImage: "house", value: 0) { Text(verbatim: "home") }
                Tab("Class table", systemImage: "tablecells", value: 1) { Text(verbatim: "class table") }
                Tab("More", systemImage: "ellipsis", value: 2) { Text(verbatim: "more") }
            }
            .background(
                ClassTableTabBarGestures(
                    tabTitle: "Class table",
                    isShowingClassTable: selection == 1,
                    store: store,
                    userName: "B11300000",
                    showClassTable: { selection = 1 }
                )
            )
        }
    }

    private struct Hosted {
        let window: UIWindow
        let handler: ClassTableTabBarHandler
        let bar: UIView
        let tab: CGRect
    }

    private func host(_ store: ImportedClassTableStore, requestImport: @escaping () -> Void = {}) async throws -> Hosted {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.rootViewController = UIHostingController(
            rootView: Tabs(store: store).environment(\.requestClassTableImport, requestImport)
        )
        window.makeKeyAndVisible()
        try await waitUntil { Self.finder(in: window)?.handler.classTableTabFrame() != nil }
        let handler = try #require(Self.finder(in: window)?.handler)
        return Hosted(
            window: window,
            handler: handler,
            bar: try #require(handler.bar),
            tab: try #require(handler.classTableTabFrame())
        )
    }

    private static func finder(in view: UIView) -> TabBarFinder? {
        if let finder = view as? TabBarFinder { return finder }
        return view.subviews.lazy.compactMap { finder(in: $0) }.first
    }

    private static func neighbour(of tab: CGRect) -> CGPoint {
        CGPoint(x: tab.midX - tab.width, y: tab.midY)
    }

    @Test("the gestures go on the bar that shows the tabs, at the bottom on iPhone and on top on iPad")
    func gesturesOnTheShownBar() async throws {
        let people = try Self.people(Folder())
        let hosted = try await host(people.store)
        defer { hosted.window.isHidden = true }

        #expect(hosted.bar.window === hosted.window)
        let barFrame = hosted.bar.convert(hosted.bar.bounds, to: hosted.window)
        if UIDevice.current.userInterfaceIdiom == .pad {
            #expect(barFrame.midY < hosted.window.bounds.midY)
        } else {
            #expect(hosted.bar is UITabBar)
            #expect(barFrame.midY > hosted.window.bounds.midY)
        }
        #expect(hosted.bar.interactions.contains { $0 is UIContextMenuInteraction })
    }

    @Test("the tab bar's Import asks the presenter of its own window, so another window opens nothing")
    func importStaysInItsWindow() async throws {
        let people = try Self.people(Folder())
        let here = Count()
        let elsewhere = Count()
        let hosted = try await host(people.store) { here.value += 1 }
        defer { hosted.window.isHidden = true }
        let other = try await host(people.store) { elsewhere.value += 1 }
        defer { other.window.isHidden = true }

        ClassTableSwitcherEntry.importClassTable.choose(in: people.store, requestImport: hosted.handler.requestImport)

        #expect(here.value == 1)
        #expect(elsewhere.value == 0)
    }

    @Test("the long press opens the switcher on the class table tab and on no other")
    func longPressOnlyOnTheClassTableTab() async throws {
        let people = try Self.people(Folder())
        let hosted = try await host(people.store)
        defer { hosted.window.isHidden = true }
        let interaction = try #require(hosted.bar.interactions.compactMap { $0 as? UIContextMenuInteraction }.first)

        let onTab = hosted.handler.contextMenuInteraction(
            interaction, configurationForMenuAtLocation: CGPoint(x: hosted.tab.midX, y: hosted.tab.midY)
        )
        #expect(onTab?.preferredMenuElementOrder == .fixed)
        #expect(hosted.handler.contextMenuInteraction(
            interaction, configurationForMenuAtLocation: Self.neighbour(of: hosted.tab)
        ) == nil)
    }

    @Test("a double tap on the class table tab cycles user, people, user, only when it was showing")
    func doubleTapCycles() async throws {
        let people = try Self.people(Folder())
        let hosted = try await host(people.store)
        defer { hosted.window.isHidden = true }
        let center = CGPoint(x: hosted.tab.midX, y: hosted.tab.midY)

        hosted.handler.doubleTapped(at: center, startedOnClassTable: false)
        #expect(people.store.shownPersonID == nil)

        hosted.handler.doubleTapped(at: center, startedOnClassTable: true)
        #expect(people.store.shownPersonID == people.ming.id)
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true)
        #expect(people.store.shownPersonID == people.hua.id)
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true)
        #expect(people.store.shownPersonID == nil)

        hosted.handler.doubleTapped(at: Self.neighbour(of: hosted.tab), startedOnClassTable: true)
        #expect(people.store.shownPersonID == nil)
    }

    @Test("a double tap over 1.5 s after the last goes back to the class table before; quicker ones step through the list")
    func doubleTapGoesBackAfterAPause() async throws {
        let people = try Self.people(Folder())
        let hosted = try await host(people.store)
        defer { hosted.window.isHidden = true }
        let center = CGPoint(x: hosted.tab.midX, y: hosted.tab.midY)
        let start = ContinuousClock.now
        people.store.show(people.ming.id)
        people.store.show(people.hua.id)

        hosted.handler.doubleTapped(at: center, startedOnClassTable: true, now: start)
        #expect(people.store.shownPersonID == people.ming.id)
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true, now: start + .milliseconds(1500))
        #expect(people.store.shownPersonID == people.hua.id)
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true, now: start + .milliseconds(3100))
        #expect(people.store.shownPersonID == people.ming.id)
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true, now: start + .seconds(8))
        #expect(people.store.shownPersonID == people.hua.id)
    }

    @Test("the double tap lets every tap through at once, so a single tap still switches tabs at once")
    func doubleTapDelaysNothing() async throws {
        let people = try Self.people(Folder())
        let hosted = try await host(people.store)
        defer { hosted.window.isHidden = true }

        let recognizer = try #require(hosted.bar.gestureRecognizers?.compactMap { $0 as? ClassTableTabDoubleTap }.first)
        #expect(recognizer.numberOfTapsRequired == 2)
        #expect(!recognizer.delaysTouchesBegan)
        #expect(!recognizer.delaysTouchesEnded)
        #expect(!recognizer.cancelsTouchesInView)
    }

    @Test("the double tap keeps whether the class table showed at its first tap, until it resets")
    func doubleTapRemembersItsFirstTap() {
        let recognizer = ClassTableTabDoubleTap(target: nil, action: nil)
        var showing = false
        recognizer.isShowingClassTable = { showing }

        recognizer.touchesBegan([], with: UIEvent())
        showing = true
        recognizer.touchesBegan([], with: UIEvent())
        #expect(!recognizer.startedOnClassTable)

        recognizer.reset()
        recognizer.touchesBegan([], with: UIEvent())
        #expect(recognizer.startedOnClassTable)
    }

    @Test("someone else's menu has the screenshot and calendar exports, import, rename and delete user, and nothing else")
    func otherPersonMenu() {
        #expect(ClassTableOtherPersonAction.sections == [
            [.exportScreenshot, .exportCalendar], [.importClassTable], [.rename, .deleteUser],
        ])
        #expect(ClassTableOtherPersonAction.sections.joined().map(\.title) == [
            String(localized: "class_table_export_screenshot"),
            String(localized: "class_table_export_ics"),
            String(localized: "class_table_import"),
            String(localized: "class_table_rename_title"),
            String(localized: "class_table_delete_user"),
        ])
        #expect(ClassTableOtherPersonAction.sections.joined().filter { $0.role == .destructive } == [.deleteUser])
    }

    private struct CourseCells: View {
        var body: some View {
            VStack(spacing: 0) {
                Color.blue.frame(height: 200)
                    .courseEditMenu(isEditable: true) { Button("Rename") {} }
                Color.red.frame(height: 200)
                    .courseEditMenu(isEditable: false) { Button("Rename") {} }
            }
            .ignoresSafeArea()
        }
    }

    @Test("a long press on a course of someone else's class table opens no menu")
    func noCourseMenuOnAnotherTable() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 400)
        window.rootViewController = UIHostingController(rootView: CourseCells())
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var interaction: UIContextMenuInteraction?
        try await waitUntil {
            interaction = Self.views(in: window).lazy.compactMap {
                $0.interactions.compactMap { $0 as? UIContextMenuInteraction }.first
            }.first
            return interaction != nil
        }
        let menus = try #require(interaction)
        let host = try #require(menus.view)

        let editable = window.convert(CGPoint(x: 195, y: 100), to: host)
        let readOnly = window.convert(CGPoint(x: 195, y: 300), to: host)
        #expect(menus.delegate?.contextMenuInteraction(menus, configurationForMenuAtLocation: editable) != nil)
        #expect(menus.delegate?.contextMenuInteraction(menus, configurationForMenuAtLocation: readOnly) == nil)
    }

    private static func views(in view: UIView) -> [UIView] {
        [view] + view.subviews.flatMap(views)
    }
}
#endif
