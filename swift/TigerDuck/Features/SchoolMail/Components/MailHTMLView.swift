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
    @Binding var contentHeight: CGFloat
    let onLinkTap: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: MailWebViewFactory.makeConfiguration(inlineImages: inlineImages))
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        webView.backgroundColor = .white
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
                Task { @MainActor in self.parent.contentHeight = max(height, 1) }
            }
        }

        func load(into webView: WKWebView) {
            let key = "\(parent.allowRemoteImages)|\(parent.html.hashValue)"
            guard key != loadedKey else { return }
            loadedKey = key
            let document = MailWebViewFactory.document(for: parent.html, allowRemoteImages: parent.allowRemoteImages)
            let allowImages = parent.allowRemoteImages
            Task { @MainActor in
                await MailWebViewFactory.installRules(on: webView, allowRemoteImages: allowImages)
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
