import Defaults
import SwiftUI
import UIKit

/// Where a link the app opens goes: the TigerDuck browser, or the system, which hands it to
/// another app or the default browser.
nonisolated enum LinkRouting {
    enum Destination: Equatable {
        case browser(URL)
        case system(URL)
    }

    /// An https page opens in the browser under the in-app preference and in the default browser
    /// under the system one. A Moodle app link opens the app when it is installed, and otherwise
    /// the page it names in the browser whatever the preference, as the browser signs in to
    /// Moodle. Anything else, plain http and the App Store too, goes to the system.
    static func destination(for url: URL, moodleAppInstalled: Bool, preference: BrowserPreference) -> Destination {
        switch url.scheme?.lowercased() {
        case "moodlemobile":
            guard !moodleAppInstalled, let page = moodlePage(in: url) else { return .system(url) }
            return .browser(page)
        case "https" where preference == .inApp && !BrowserRouting.isAppStore(url):
            return .browser(url)
        default:
            return .system(url)
        }
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

    /// Pages the student fills in, which tapping a reminder leaves open.
    private static let keptPages: Set<URL> = [AppURLs.issues, AppURLs.deleteAccount]

    func body(content: Content) -> some View {
        content
            .environment(\.openURL, OpenURLAction { route($0) })
            .fullScreenCover(item: $page) { page in
                TigerDuckBrowserView(url: page.url)
                    .keptOverReminders(Self.keptPages.contains(page.url))
            }
    }

    private func route(_ url: URL) -> OpenURLAction.Result {
        // canOpenURL answers for moodlemobile because Info.plist lists it in LSApplicationQueriesSchemes.
        let installed = url.scheme?.lowercased() == "moodlemobile" && UIApplication.shared.canOpenURL(url)
        switch LinkRouting.destination(for: url, moodleAppInstalled: installed, preference: Defaults[.browserPreference]) {
        case .browser(let url):
            page = BrowserLink(url: url)
        case .system(let url) where MoodleAutologinService.isMoodlePage(url):
            // The default browser has no Moodle session, so the page opens through a one-time sign-in link.
            Task { openOutside(await MoodleAutologinService.shared.url(for: url)) }
        case .system(let url):
            openOutside(url)
        }
        return .handled
    }
}

private struct BrowserLink: Identifiable {
    let url: URL
    var id: URL { url }
}
