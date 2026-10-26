import SwiftUI
import UIKit

/// Where a link the app opens goes: the TigerDuck browser, or the system, which hands it to
/// another app or the default browser.
nonisolated enum LinkRouting {
    enum Destination: Equatable {
        case browser(URL)
        case system(URL)
    }

    /// A page the browser loads, a school page, opens in it; any other link goes to the system,
    /// where the browser would send it too. A Moodle app link opens the app when it is installed,
    /// and otherwise the page it names in the browser, which signs in to Moodle.
    static func destination(for url: URL, moodleAppInstalled: Bool) -> Destination {
        if url.scheme?.lowercased() == "moodlemobile" {
            guard !moodleAppInstalled, let page = moodlePage(in: url) else { return .system(url) }
            return .browser(page)
        }
        return BrowserRouting.decision(for: url) == .load ? .browser(url) : .system(url)
    }

    /// The Moodle page a link from `AppConstants.moodleDeepLink(redirectingTo:)` names.
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
