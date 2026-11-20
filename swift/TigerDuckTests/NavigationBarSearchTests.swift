#if os(iOS)
import SwiftUI
import Testing
import UIKit
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct NavigationBarSearchTests {
    @Observable
    fileprivate final class Search {
        var text = ""
        var isPresented = false
        var tab = 0
        var pushed = false
        var sheet = false
        var searches = true

        init(text: String = "", isPresented: Bool = false) {
            self.text = text
            self.isPresented = isPresented
        }
    }

    private struct Page: View {
        static let rows = (0..<30).map { "Row \($0)" }
        @Bindable var search: Search

        var body: some View {
            List { ForEach(Self.rows.filter { search.text.isEmpty || $0.contains(search.text) }, id: \.self) { Text($0) } }
                .navigationTitle("Rows")
                .modifier(Searching(search: search))
                .navigationDestination(isPresented: $search.pushed) { Text("Detail").navigationTitle("Detail") }
                .sheet(isPresented: $search.sheet) { Text("Sheet") }
        }
    }

    private struct Searching: ViewModifier {
        @Bindable var search: Search

        func body(content: Content) -> some View {
            if search.searches {
                content.navigationBarSearch(text: $search.text, isPresented: $search.isPresented, prompt: "Find a row")
            } else {
                content
            }
        }
    }

    private struct Tabs: View {
        @Bindable var search: Search

        var body: some View {
            TabView(selection: $search.tab) {
                Tab("Rows", systemImage: "list.bullet", value: 0) { NavigationStack { Page(search: search) } }
                Tab("Other", systemImage: "circle", value: 1) { Color.clear }
            }
        }
    }

    private struct Typed {
        let window: UIWindow
        let list: UICollectionView
        let bar: UISearchBar

        var navigation: UINavigationController? {
            sequence(first: list as UIResponder, next: \.next).lazy.compactMap { $0 as? UINavigationController }.first
        }

        func close() {
            window.endEditing(true)
            window.isHidden = true
        }
    }

    private static func show(_ search: Search) async throws -> (UIWindow, UICollectionView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = UIHostingController(rootView: Tabs(search: search))
        window.makeKeyAndVisible()

        try await waitUntil { window.descendants(ofType: UICollectionView.self).first.map { $0.contentSize.height > 0 } ?? false }
        return (window, try #require(window.descendants(ofType: UICollectionView.self).first))
    }

    /// The page with "Row 1" typed into its revealed search, and the list showing the matches.
    private static func typed(_ search: Search) async throws -> Typed {
        let (window, list) = try await show(search)
        list.contentOffset.y = -list.adjustedContentInset.top - 90
        try await waitUntil { !window.descendants(ofType: UISearchBar.self).isEmpty }
        let bar = try #require(window.descendants(ofType: UISearchBar.self).first)
        #expect(bar.placeholder == "Find a row")

        bar.searchTextField.becomeFirstResponder()
        try await waitUntil { search.isPresented }
        bar.searchTextField.insertText("Row 1")
        try await waitUntil { search.text == "Row 1" && list.numberOfItems(inSection: 0) == 11 }
        let typed = Typed(window: window, list: list, bar: bar)
        let navigation = try #require(typed.navigation)
        let controller = try #require(navigation.viewControllers.first?.navigationItem.searchController)
        try await waitUntil { navigation.transitionCoordinator == nil && controller.transitionCoordinator == nil }
        return typed
    }

    @Test("typing reaches the page's text, and the page clearing and closing the search empties and closes the field")
    func bindings() async throws {
        let search = Search()
        let page = try await Self.typed(search)
        defer { page.close() }

        search.isPresented = false
        search.text = ""
        try await waitUntil { page.bar.searchTextField.text?.isEmpty == true && !page.bar.searchTextField.isFirstResponder }
        #expect(page.list.numberOfItems(inSection: 0) == 30)
    }

    @Test("the cancel button empties the text and ends the search")
    func cancel() async throws {
        let search = Search()
        let page = try await Self.typed(search)
        defer { page.close() }
        let barBottom = page.bar.convert(page.bar.bounds, to: page.window).maxY
        let cancel = try #require(page.window.descendants(ofType: UIButton.self).first {
            !$0.isDescendant(of: page.bar.searchTextField) && $0.convert($0.bounds, to: page.window).minY < barBottom
        })

        cancel.sendActions(for: .touchUpInside)
        try await waitUntil { !search.isPresented && !page.bar.searchTextField.isFirstResponder }

        #expect(search.text.isEmpty)
        #expect(page.bar.searchTextField.text?.isEmpty == true)
        try await waitUntil { page.list.numberOfItems(inSection: 0) == 30 }
    }

    @Test("the field's clear button empties the text and keeps the search")
    func clear() async throws {
        let search = Search()
        let page = try await Self.typed(search)
        defer { page.close() }
        let clear = try #require(page.bar.searchTextField.descendants(ofType: UIButton.self).first)

        clear.sendActions(for: .touchUpInside)
        try await waitUntil { search.text.isEmpty && page.list.numberOfItems(inSection: 0) == 30 }

        #expect(search.isPresented)
        #expect(page.bar.searchTextField.isFirstResponder)
    }

    @Test("switching to another tab and back keeps the text and the search")
    func tabs() async throws {
        let search = Search()
        let page = try await Self.typed(search)
        defer { page.close() }

        search.tab = 1
        try await waitUntil { page.list.window == nil }
        search.tab = 0
        try await waitUntil { page.list.window != nil && page.bar.searchTextField.isFirstResponder }

        #expect(search.text == "Row 1")
        #expect(search.isPresented)
        #expect(page.bar.searchTextField.text == "Row 1")
        #expect(page.list.numberOfItems(inSection: 0) == 11)
    }

    @Test("a page pushed during a search covers the search, and coming back finds it active with its text and no keyboard")
    func pushAndBack() async throws {
        let search = Search()
        let page = try await Self.typed(search)
        defer { page.close() }
        let navigation = try #require(page.navigation)

        search.pushed = true
        try await waitUntil { navigation.viewControllers.count == 2 && navigation.transitionCoordinator == nil }
        #expect(page.bar.window == nil)
        #expect(!page.bar.searchTextField.isFirstResponder)

        search.pushed = false
        try await waitUntil { navigation.viewControllers.count == 1 && navigation.transitionCoordinator == nil }
        #expect(search.isPresented)
        #expect(search.text == "Row 1")
        #expect(page.bar.window != nil)
        #expect(page.bar.searchTextField.text == "Row 1")
        #expect(!page.bar.searchTextField.isFirstResponder)
        #expect(page.list.numberOfItems(inSection: 0) == 11)
    }

    @Test("a sheet opened during a search goes over it, and closing it finds the search active with its text and keyboard")
    func sheetAndBack() async throws {
        let search = Search()
        let page = try await Self.typed(search)
        defer { page.close() }
        let root = try #require(page.window.rootViewController)

        search.sheet = true
        try await waitUntil { root.presentedViewController.map { $0.transitionCoordinator == nil } ?? false }
        #expect(!(root.presentedViewController is UISearchController))

        search.sheet = false
        try await waitUntil { root.presentedViewController == nil }
        #expect(search.isPresented)
        #expect(search.text == "Row 1")
        #expect(page.bar.searchTextField.text == "Row 1")
        #expect(page.bar.searchTextField.isFirstResponder)
        #expect(page.list.numberOfItems(inSection: 0) == 11)
    }

    @Test("a search already open with text when the page first shows is shown open with that text")
    func openAtFirstShow() async throws {
        let search = Search(text: "Row 1", isPresented: true)
        let (window, list) = try await Self.show(search)
        defer {
            window.endEditing(true)
            window.isHidden = true
        }

        try await waitUntil(timeout: .seconds(5)) { window.descendants(ofType: UISearchBar.self).contains { $0.window != nil } }
        let bar = try #require(window.descendants(ofType: UISearchBar.self).first)
        try await waitUntil(timeout: .seconds(5)) { bar.searchTextField.isFirstResponder }
        #expect(search.isPresented)
        #expect(bar.text == "Row 1")
        #expect(list.numberOfItems(inSection: 0) == 11)
    }

    @Test("taking the search off a page that stays removes its bar")
    func removed() async throws {
        let search = Search()
        let (window, list) = try await Self.show(search)
        defer { window.isHidden = true }
        let navigation = sequence(first: list as UIResponder, next: \.next).lazy.compactMap { $0 as? UINavigationController }.first
        let page = try #require(navigation?.viewControllers.first)
        try await waitUntil { page.navigationItem.searchController != nil }

        search.searches = false
        try await waitUntil(timeout: .seconds(5)) { page.navigationItem.searchController == nil }
        #expect(window.descendants(ofType: UISearchBar.self).allSatisfy { $0.window == nil })
    }
}
#endif
