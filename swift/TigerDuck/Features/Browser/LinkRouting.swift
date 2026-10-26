import SwiftUI
import UIKit

/// One place decides where every link the app opens goes, so no screen opens a school page
/// outside the TigerDuck browser.
nonisolated enum LinkRouting {
    enum Destination: Equatable {
        case browser(URL)
        case system(URL)
    }

    /// The browser hands any page it would not load to the system, so only those it loads open
    /// in it. Without the Moodle app, a Moodle app link opens its page in the browser, which
    /// signs in to Moodle.
    static func destination(for url: URL, moodleAppInstalled: Bool) -> Destination {
        if url.scheme?.lowercased() == "moodlemobile" {
            guard !moodleAppInstalled, let page = moodlePage(in: url) else { return .system(url) }
            return .browser(page)
        }
        return BrowserRouting.decision(for: url) == .load ? .browser(url) : .system(url)
    }

    /// Only a site-relative path is taken, so a crafted link cannot send the browser off Moodle.
    static func moodlePage(in link: URL) -> URL? {
        let text = link.absoluteString
        guard let start = text.range(of: "?redirect=")?.upperBound,
              let path = text[start...].removingPercentEncoding,
              path.hasPrefix("/"), !path.hasPrefix("//") else { return nil }
        return URL(string: path, relativeTo: AppConstants.moodleBaseURL)?.absoluteURL
    }
}

extension View {
    /// Opens every link the content opens where `LinkRouting` says, showing the TigerDuck
    /// browser over this view. SwiftUI presents nothing over another presentation, so a sheet
    /// that opens links gets its own.
    func linkRouting() -> some View {
        modifier(LinkRoutingHost())
    }
}

private struct LinkRoutingHost: ViewModifier {
    @Environment(\.openURL) private var openOutside
    @State private var page: BrowserLink?

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { route($0) })
            .fullScreenCover(item: $page) { TigerDuckBrowserView(url: $0.url) }
    }

    private func route(_ url: URL) -> OpenURLAction.Result {
        // canOpenURL answers for moodlemobile because Info.plist lists it in LSApplicationQueriesSchemes.
        let installed = url.scheme?.lowercased() == "moodlemobile" && UIApplication.shared.canOpenURL(url)
        switch LinkRouting.destination(for: url, moodleAppInstalled: installed) {
        case .browser(let url): page = BrowserLink(url: url)
        case .system(let url): openOutside(url)
        }
        return .handled
    }
}

private struct BrowserLink: Identifiable {
    let url: URL
    var id: URL { url }
}
