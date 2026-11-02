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
    }

    private struct Page: View {
        static let rows = (0..<30).map { "Row \($0)" }
        @Bindable var search: Search

        var body: some View {
            List { ForEach(Self.rows.filter { search.text.isEmpty || $0.contains(search.text) }, id: \.self) { Text($0) } }
                .navigationTitle("Rows")
                .navigationBarSearch(text: $search.text, isPresented: $search.isPresented, prompt: "Find a row")
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

        func close() {
            window.endEditing(true)
            window.isHidden = true
        }
    }

    /// The page with "Row 1" typed into its revealed search, and the list showing the matches.
    private static func typed(_ search: Search) async throws -> Typed {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = UIHostingController(rootView: Tabs(search: search))
        window.makeKeyAndVisible()

        try await waitUntil { window.descendants(ofType: UICollectionView.self).first.map { $0.contentSize.height > 0 } ?? false }
        let list = try #require(window.descendants(ofType: UICollectionView.self).first)
        list.contentOffset.y = -list.adjustedContentInset.top - 90
        try await waitUntil { !window.descendants(ofType: UISearchBar.self).isEmpty }
        let bar = try #require(window.descendants(ofType: UISearchBar.self).first)
        #expect(bar.placeholder == "Find a row")

        bar.searchTextField.becomeFirstResponder()
        try await waitUntil { search.isPresented }
        bar.searchTextField.insertText("Row 1")
        try await waitUntil { search.text == "Row 1" && list.numberOfItems(inSection: 0) == 11 }
        return Typed(window: window, list: list, bar: bar)
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
        #expect(page.list.numberOfItems(inSection: 0) == 30)
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
}
#endif
