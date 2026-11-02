import Foundation

@MainActor
struct BrowserDemoPages {
    enum Decision: Equatable {
        case allow
        case show(String)
        case refuse
    }

    private let page: (URL) -> String?

    init(page: @escaping (URL) -> String? = { DemoPortal.page(for: $0) }) {
        self.page = page
    }

    func decide(_ url: URL) -> Decision {
        // WebKit asks for a page loaded with `loadHTMLString(_:baseURL: nil)` as `about:blank`.
        if url.scheme?.lowercased() == "about" { return .allow }
        return page(url).map(Decision.show) ?? .refuse
    }
}
