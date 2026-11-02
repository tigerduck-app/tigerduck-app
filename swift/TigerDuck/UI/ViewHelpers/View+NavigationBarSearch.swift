import SwiftUI
#if os(iOS)
import UIKit
#endif

extension View {
    /// `.searchable` in the navigation bar's drawer, folded when a tab's root page first shows.
    @ViewBuilder
    func navigationBarSearch(text: Binding<String>, isPresented: Binding<Bool>? = nil, prompt: String) -> some View {
        #if os(iOS)
        if #available(iOS 27, *) {
            systemSearch(text: text, isPresented: isPresented, prompt: prompt)
        } else if #available(iOS 26, *) {
            // iOS 26's .searchable opens a root page's drawer on its first show; UIKit's search controller folds it.
            background(NavigationBarSearchController(text: text, isPresented: isPresented, prompt: prompt))
        } else {
            systemSearch(text: text, isPresented: isPresented, prompt: prompt)
        }
        #else
        systemSearch(text: text, isPresented: isPresented, prompt: prompt)
        #endif
    }

    @ViewBuilder
    private func systemSearch(text: Binding<String>, isPresented: Binding<Bool>?, prompt: String) -> some View {
        if let isPresented {
            searchable(text: text, isPresented: isPresented, prompt: prompt)
        } else {
            searchable(text: text, prompt: prompt)
        }
    }
}

#if os(iOS)
/// A `UISearchController` on the navigation item of the page this view is in.
private struct NavigationBarSearchController: UIViewControllerRepresentable {
    let text: Binding<String>
    let isPresented: Binding<Bool>?
    let prompt: String
    /// SwiftUI updates a representable only when its stored values change, so it keeps the bindings' values too.
    private let textValue: String
    private let presentedValue: Bool?

    init(text: Binding<String>, isPresented: Binding<Bool>?, prompt: String) {
        self.text = text
        self.isPresented = isPresented
        self.prompt = prompt
        textValue = text.wrappedValue
        presentedValue = isPresented?.wrappedValue
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: text, isPresented: isPresented) }

    func makeUIViewController(context: Context) -> Host {
        let host = Host()
        host.search.searchResultsUpdater = context.coordinator
        host.search.delegate = context.coordinator
        return host
    }

    func updateUIViewController(_ host: Host, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = text
        coordinator.isPresented = isPresented
        let search = host.search
        search.searchBar.placeholder = prompt
        // Setting the field's text mid-typing would end marked-text input, so only outside changes are written.
        if textValue != coordinator.shownText {
            coordinator.shownText = textValue
            search.searchBar.text = textValue
        }
        if let presentedValue, presentedValue != coordinator.shownPresented {
            coordinator.shownPresented = presentedValue
            search.isActive = presentedValue
        }
    }

    final class Coordinator: NSObject, UISearchResultsUpdating, UISearchControllerDelegate {
        var text: Binding<String>
        var isPresented: Binding<Bool>?
        var shownText = ""
        var shownPresented = false

        init(text: Binding<String>, isPresented: Binding<Bool>?) {
            self.text = text
            self.isPresented = isPresented
        }

        func updateSearchResults(for searchController: UISearchController) {
            shownText = searchController.searchBar.text ?? ""
            if text.wrappedValue != shownText { text.wrappedValue = shownText }
        }

        func willPresentSearchController(_ searchController: UISearchController) {
            shownPresented = true
            isPresented?.wrappedValue = true
        }

        func willDismissSearchController(_ searchController: UISearchController) {
            shownPresented = false
            isPresented?.wrappedValue = false
        }
    }

    final class Host: UIViewController {
        let search = UISearchController(searchResultsController: nil)

        override func viewIsAppearing(_ animated: Bool) {
            super.viewIsAppearing(animated)
            var page = parent
            while let current = page, !(current.parent is UINavigationController) { page = current.parent }
            guard let page, page.navigationItem.searchController !== search else { return }
            page.navigationItem.searchController = search
        }
    }
}
#endif
