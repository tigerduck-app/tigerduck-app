import Defaults
import Foundation

nonisolated enum DemoPortal {
    static func links(in language: PortalLanguage, fixture: DemoFixture? = .bundled) -> [PortalLink] {
        let shown: DemoLanguage = language == .zh ? .zh : .en
        return (fixture?.informationSystem ?? []).compactMap { $0.link(in: shown) }
    }

    static func page(
        for url: URL,
        language: PortalLanguage = PortalLanguage(appLanguage: Defaults[.appLanguage]),
        fixture: DemoFixture? = .bundled
    ) -> String? {
        links(in: language, fixture: fixture).first { $0.url == url }.map(page)
    }

    static func page(_ link: PortalLink) -> String {
        let name = escaped(link.name)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="color-scheme" content="light dark">
        <title>\(name)</title>
        <style>body { font: -apple-system-body; margin: 24px; } p { color: GrayText; }</style>
        </head><body>
        <p>\(escaped(String(localized: link.category.titleKey)))</p>
        <h1>\(name)</h1>
        </body></html>
        """
    }

    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

nonisolated extension DemoFixture.PortalEntry {
    func link(in language: DemoLanguage) -> PortalLink? {
        guard let category = PortalCategory(rawValue: self.category), let url = URL(string: url) else { return nil }
        return PortalLink(category: category, name: name.text(in: language), url: url)
    }
}
