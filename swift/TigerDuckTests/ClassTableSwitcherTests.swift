#if os(iOS)
import SwiftUI
import Testing
import UIKit
import UIKit.UIGestureRecognizerSubclass
@testable import TigerDuck

/// The class table switcher: the rows it lists and their order in the tab bar's menu, the tab the
/// long press and the double tap answer on the system tab bar, the double tap's rule, the menu of
/// someone else's class table, and that a course on it has no menu.
@MainActor
@Suite(.serialized)
struct ClassTableSwitcherTests {
    /// A folder removed when the test ends, holding the store's file.
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
        let ming = try #require(store.add(code("B11300001"), nickname: "Ming", courses: [:]))
        let hua = try #require(store.add(code("B11300002"), nickname: "Hua", courses: [:]))
        return People(store: store, ming: ming, hua: hua)
    }

    // MARK: - The rows

    @Test("the switcher lists import first, then the people in import order, then the user")
    func rowsInOrder() throws {
        let people = try Self.people(Folder())
        people.store.show(people.hua.id)

        #expect(ClassTableSwitcherEntry.sections(in: people.store, userName: "B11300000") == [
            [.importClassTable],
            [
                .person(id: people.ming.id, nickname: "Ming", isShown: false),
                .person(id: people.hua.id, nickname: "Hua", isShown: true),
            ],
            [.user(name: "B11300000", isShown: false)],
        ])
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

    /// `opensUpward`: the bar is at the bottom, as on iPhone; otherwise at the top, as on iPad.
    @Test("the tab bar's menu keeps the user's row next to the tab", arguments: [true, false])
    func tabMenuOrder(opensUpward: Bool) throws {
        let people = try Self.people(Folder())
        people.store.show(people.ming.id)

        let menu = ClassTableTabBarHandler.menu(
            ClassTableSwitcherEntry.sections(in: people.store, userName: "B11300000"),
            opensUpward: opensUpward
        ) { _ in }

        let sections = menu.children.compactMap { $0 as? UIMenu }
        let rows = sections.map { $0.children.compactMap { $0 as? UIAction } }
        let expected = [[String(localized: "class_table_import")], ["Ming", "Hua"], ["B11300000"]]
        #expect(rows.map { $0.map(\.title) } == (opensUpward ? expected : expected.reversed().map { $0.reversed() }))
        #expect(sections.count == menu.children.count)
        #expect(sections.allSatisfy { $0.options.contains(.displayInline) })
        #expect(rows.joined().filter { $0.state == .on }.map(\.title) == ["Ming"])
    }

    // MARK: - On the tab bar

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
        /// The class table tab in the bar's coordinates.
        let tab: CGRect
    }

    /// A full-screen window, so the bar lays out as the app's does: at the bottom on iPhone, and
    /// at the top, apart from the controller's own tab bar, on iPad.
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

    /// The tab before the class table's, Home, in a left-to-right bar.
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

    @Test("a double tap after a pause goes back to the class table before; quick ones step through the list")
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
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true, now: start + .seconds(2))
        #expect(people.store.shownPersonID == people.hua.id)
        hosted.handler.doubleTapped(at: center, startedOnClassTable: true, now: start + .seconds(4))
        #expect(people.store.shownPersonID == nil)
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
        // The first tap switched to the class table before the second came down.
        showing = true
        recognizer.touchesBegan([], with: UIEvent())
        #expect(!recognizer.startedOnClassTable)

        recognizer.reset()
        recognizer.touchesBegan([], with: UIEvent())
        #expect(recognizer.startedOnClassTable)
    }

    // MARK: - Someone else's class table

    @Test("someone else's menu has export, import, rename and delete user, and nothing else")
    func otherPersonMenu() {
        #expect(ClassTableOtherPersonAction.sections == [[.exportScreenshot], [.importClassTable], [.rename, .deleteUser]])
        #expect(ClassTableOtherPersonAction.sections.joined().map(\.title) == [
            String(localized: "class_table_export_screenshot"),
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
