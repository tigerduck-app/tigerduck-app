#if os(iOS)
import SwiftUI
import UIKit
import WebKit

/// Where the "use another app" guide lives, and which URLs belong to it.
///
/// The guide is served from the website rather than written into the app, so the steps can be
/// corrected without shipping a build — the same page the Android app embeds, on its own
/// platform segment.
nonisolated enum MailGuide {
    static let host = "tigerduck.app"
    static let pathPrefix = "/help/receive-mail/"
    /// What "Open in browser" opens: the ordinary page, with none of the embedding parameters.
    static let publicURL = URL.knownGood("https://tigerduck.app/help/receive-mail/apple")

    /// The embedded form: page content only, in the app's theme, language and colours, so the
    /// web view's edge does not show against the screen around it.
    static func embedURL(isDark: Bool, languageTag: String, background: UInt32, foreground: UInt32) -> URL {
        var components = URLComponents(url: publicURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "embed", value: "1"),
            URLQueryItem(name: "theme", value: isDark ? "dark" : "light"),
            URLQueryItem(name: "lang", value: languageTag),
            URLQueryItem(name: "bg", value: MailHTMLTheme.css(background)),
            URLQueryItem(name: "fg", value: MailHTMLTheme.css(foreground)),
        ]
        // `URLQueryItem` leaves `#` alone in a value, and a bare `#` would end the query there.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "#", with: "%23")
        return components.url!
    }

    /// Whether `url` is a page of the guide, compared part by part rather than as a string
    /// prefix: `https://tigerduck.app@evil.com/help/receive-mail/…` starts with the right
    /// characters and is somewhere else entirely.
    static func isGuideURL(_ url: URL?) -> Bool {
        guard let url = url?.standardized,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host,
              url.user == nil, url.password == nil,
              url.port == nil || url.port == 443 else { return false }
        return url.path.hasPrefix(pathPrefix) || url.path + "/" == pathPrefix
    }

    enum NavigationDecision: Equatable {
        case allow, openExternally, refuse
    }

    /// The guide's own pages load in place. Anything else the *page* navigates to is a link the
    /// user tapped, and opens in their browser; anything else a *subframe* loads is refused — an
    /// embedded frame's own navigation is not something the user asked to open.
    static func decision(for url: URL?, isMainFrame: Bool) -> NavigationDecision {
        if isGuideURL(url) { return .allow }
        return isMainFrame ? .openExternally : .refuse
    }

    /// A main-frame HTTP error. WebKit reports only transport failures through `didFail…`; a 404
    /// or 502 would otherwise render the server's own error body inside the screen, with no way
    /// to retry.
    static func isLoadFailure(statusCode: Int, isMainFrame: Bool) -> Bool {
        isMainFrame && statusCode >= 400
    }

    /// Failures that are not the page failing: a navigation this view cancelled itself (a link
    /// handed to the browser, an HTTP error it already reported).
    static func isIgnorable(_ error: NSError) -> Bool {
        (error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled)
            || (error.domain == "WebKitErrorDomain" && error.code == 102)
    }
}

/// The guide page, drawn on `background` from before its first paint so no white shows.
///
/// JavaScript is on: the page is the website's own single-page app, and it renders nothing
/// without it. Everything around that is kept narrow — a non-persistent store, no script
/// bridge, no windows, and navigation confined to the guide's own pages (`MailGuide.decision`).
/// App Transport Security already refuses plain-HTTP loads, mixed content included.
struct MailGuideWebView: UIViewRepresentable {
    let url: URL
    let background: UIColor
    let onExternalLink: (URL) -> Void
    let onError: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.dataDetectorTypes = []
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.isOpaque = false
        webView.backgroundColor = background
        webView.scrollView.backgroundColor = background
        webView.underPageBackgroundColor = background
        #if DEBUG
        webView.isInspectable = true
        #endif
        webView.load(URLRequest(url: url))
        context.coordinator.loadedURL = url
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        // A language change rebuilds the URL; anything else is the same page.
        guard context.coordinator.loadedURL != url else { return }
        context.coordinator.loadedURL = url
        webView.load(URLRequest(url: url))
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: MailGuideWebView
        var loadedURL: URL?

        init(parent: MailGuideWebView) { self.parent = parent }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            let url = navigationAction.request.url
            let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
            switch MailGuide.decision(for: url, isMainFrame: isMainFrame) {
            case .allow:
                return .allow
            case .openExternally:
                if let url { parent.onExternalLink(url) }
                return .cancel
            case .refuse:
                return .cancel
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if let response = navigationResponse.response as? HTTPURLResponse,
               MailGuide.isLoadFailure(statusCode: response.statusCode, isMainFrame: navigationResponse.isForMainFrame) {
                parent.onError()
                return .cancel
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
            report(error)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            parent.onError()
        }

        /// `target="_blank"`: never a second web view. A guide page loads in place; anything else
        /// goes to the browser like any other link.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if MailGuide.isGuideURL(url) {
                    webView.load(URLRequest(url: url))
                } else {
                    parent.onExternalLink(url)
                }
            }
            return nil
        }

        private func report(_ error: any Error) {
            guard !MailGuide.isIgnorable(error as NSError) else { return }
            parent.onError()
        }
    }
}
#endif
