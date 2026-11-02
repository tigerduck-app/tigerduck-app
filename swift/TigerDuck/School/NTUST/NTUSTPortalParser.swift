import Foundation
import SwiftSoup

/// The student portal, `i.ntust.edu.tw/student` or its English page, holds its links in a
/// `#service` block whose children are the groups, each named by its id (`PortalCategory`).
nonisolated enum NTUSTPortalParser {
    /// The portal still links the research ethics course at `ae.ntust.edu.tw`, whose certificate
    /// covers only `*.cge.ntust.edu.tw`; the course is served at `ae.cge.ntust.edu.tw`.
    private static let movedHosts = ["ae.ntust.edu.tw": "ae.cge.ntust.edu.tw"]

    /// Nil for a page with no `#service` block, which a lapsed session or a redesigned page
    /// serves, unlike a portal with no links.
    static func links(in html: String, pageURL: URL) -> [PortalLink]? {
        guard let document = try? SwiftSoup.parse(html),
              let service = try? document.getElementById("service") else { return nil }
        return service.children().array().flatMap { group -> [PortalLink] in
            guard let category = PortalCategory(rawValue: group.id()) else { return [] }
            let anchors = (try? group.select("a[href]").array()) ?? []
            return anchors.compactMap { link(from: $0, in: category, pageURL: pageURL) }
        }
    }

    private static func link(from anchor: Element, in category: PortalCategory, pageURL: URL) -> PortalLink? {
        guard let name = try? anchor.text().trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
              let href = try? anchor.attr("href").trimmingCharacters(in: .whitespacesAndNewlines),
              let resolved = URL(string: href, relativeTo: pageURL)?.absoluteURL, !isPage(resolved, pageURL),
              let url = httpsURL(for: resolved) else { return nil }
        return PortalLink(category: category, name: name, url: moved(url))
    }

    private static func isPage(_ url: URL, _ pageURL: URL) -> Bool {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.fragment = nil
        return components?.url == pageURL
    }

    private static func httpsURL(for url: URL) -> URL? {
        switch url.scheme?.lowercased() {
        case "https":
            return url
        case "http":
            guard let host = url.host(percentEncoded: false)?.lowercased(),
                  host == "ntust.edu.tw" || host.hasSuffix(".ntust.edu.tw"),
                  var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
            components.scheme = "https"
            if components.port == 80 { components.port = nil }
            return components.url
        default:
            return nil
        }
    }

    private static func moved(_ url: URL) -> URL {
        guard let host = url.host(percentEncoded: false)?.lowercased(), let movedHost = movedHosts[host],
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.host = movedHost
        return components.url ?? url
    }
}
