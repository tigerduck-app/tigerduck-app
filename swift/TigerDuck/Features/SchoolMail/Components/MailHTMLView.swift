#if os(iOS)
import SwiftUI
import WebKit

/// Sanitized mail HTML, grown to its content height so the message scrolls as one page. `html`
/// must already be `MailHTMLSanitizer.rewriteLinks`' output: every `<a href>` in it is
/// `https://link.invalid/<n>`, and `onLinkTap` is called with `n` — never a URL — so no WebKit
/// canonicalization quirk can retarget a tap (message-screen dispatch, 2026-09-16 addition 1).
struct MailHTMLView: UIViewRepresentable {
    let html: String
    let linkCount: Int
    let inlineImages: [String: MailInlineImage]
    let allowRemoteImages: Bool
    var theme: MailHTMLTheme = .app
    @Binding var contentHeight: CGFloat
    let onLinkTap: (Int) -> Void

    /// The tallest this view will grow, whatever the document's content size says.
    ///
    /// `height` and `min-height` are in `MailCSSFilter.allowedProperties`, so the sender writes
    /// `scrollView.contentSize.height` — and that went straight into `.frame(height:)` with only
    /// a lower bound. A message could therefore ask for an arbitrarily tall view. 50 000 points
    /// is far past any real mail (roughly sixty screens) and far short of a size that costs
    /// anything to lay out.
    ///
    /// `nonisolated` because `clampedHeight` is: the project defaults every declaration to
    /// `@MainActor`, so an unannotated `static let` here cannot be read from the nonisolated
    /// helper that exists precisely so the clamp can be unit-tested off the main actor.
    nonisolated static let maximumContentHeight: CGFloat = 50_000

    /// The observed content size, made safe to put in a frame: clamped at both ends, and with
    /// a non-finite value (which `contentSize` can carry mid-layout) treated as "nothing known
    /// yet" rather than propagated into the layout.
    nonisolated static func clampedHeight(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return 1 }
        return min(max(raw, 1), maximumContentHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: MailWebViewFactory.makeConfiguration(inlineImages: inlineImages))
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        // The page's own colour underneath as well as in the document, so nothing white shows
        // before the first paint or past the document's edge.
        webView.isOpaque = false
        webView.backgroundColor = theme.backgroundColor
        webView.scrollView.backgroundColor = theme.backgroundColor
        webView.underPageBackgroundColor = theme.backgroundColor
        context.coordinator.observeHeight(of: webView)
        context.coordinator.load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: webView)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MailHTMLView
        private var loadedKey: String?
        /// Bumped by every load; a load whose compile finishes after a newer one started drops
        /// itself instead of installing its rules and document over the newer ones.
        private var loadGeneration = 0
        private var loadTask: Task<Void, Never>?
        private var heightObservation: NSKeyValueObservation?

        init(parent: MailHTMLView) { self.parent = parent }

        /// `[weak self]` keeps the observation from retaining the coordinator (the coordinator
        /// owns the observation, so a strong capture would be a cycle). The weak binding is
        /// resolved *here*, in the observation callback, rather than inside the `Task`: a `weak`
        /// capture is a mutable variable, and reading one from concurrently-executing code is an
        /// error in the Swift 6 language mode. `guard let self` turns it into an immutable
        /// strong reference the `Task` can capture, which is dropped again as soon as that hop
        /// finishes — the observation itself still holds nothing.
        func observeHeight(of webView: WKWebView) {
            heightObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let self, let height = change.newValue?.height else { return }
                Task { @MainActor in self.parent.contentHeight = MailHTMLView.clampedHeight(height) }
            }
        }

        /// "Load images" loads twice in quick succession — the image allowance flips first, then
        /// the re-sanitized HTML arrives — and each load compiles its rule list asynchronously.
        /// Nothing orders those compiles, so the first load's could finish last and put the
        /// image-stripped document back on screen, under an allowance that says images are on
        /// and with the banner that offered them already gone. So only the newest load installs
        /// anything, and it installs its rules and its document together.
        func load(into webView: WKWebView) {
            let key = "\(parent.allowRemoteImages)|\(parent.theme)|\(parent.html.hashValue)"
            guard key != loadedKey else { return }
            loadedKey = key
            let document = MailWebViewFactory.document(for: parent.html, allowRemoteImages: parent.allowRemoteImages,
                                                       theme: parent.theme)
            let allowImages = parent.allowRemoteImages
            loadTask?.cancel()
            loadGeneration += 1
            let generation = loadGeneration
            loadTask = Task { @MainActor [weak self] in
                let rules = await MailWebViewFactory.compileRules(allowRemoteImages: allowImages)
                guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                MailWebViewFactory.installRules(rules, on: webView)
                webView.loadHTMLString(document, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
                if let index = MailWebViewFactory.parseLinkIndex(url.absoluteString, linkCount: parent.linkCount) {
                    parent.onLinkTap(index)
                }
                return .cancel
            }
            // Only the initial loadHTMLString document (about:blank) may load.
            return navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}
#endif
