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

    @Test("typing reaches the page's text, and the page clearing and closing the search empties and closes the field")
    func bindings() async throws {
        let search = Search()
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 375, height: 812)
        window.rootViewController = UIHostingController(rootView: TabView {
            Tab("Rows", systemImage: "list.bullet") { NavigationStack { Page(search: search) } }
        })
        window.makeKeyAndVisible()
        defer {
            window.endEditing(true)
            window.isHidden = true
        }

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

        search.isPresented = false
        search.text = ""
        try await waitUntil { bar.searchTextField.text?.isEmpty == true && !bar.searchTextField.isFirstResponder }
        #expect(list.numberOfItems(inSection: 0) == 30)
    }
}
#endif
