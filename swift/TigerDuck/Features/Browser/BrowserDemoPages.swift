import Foundation

/// The demo account reaches no server, so the browser loads no page for it: a demo portal link's
/// page is made on the device and shown as `about:blank`, the one load the demo lets through,
/// and every other page fails.
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
        if url.scheme?.lowercased() == "about" { return .allow }
        return page(url).map(Decision.show) ?? .refuse
    }
}
