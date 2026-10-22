#if os(iOS)
import SwiftUI
import WebKit

struct MailHTMLView: UIViewRepresentable {
    let html: String
    let linkCount: Int
    let inlineImages: [String: MailInlineImage]
    let allowRemoteImages: Bool
    var theme: MailHTMLTheme = .app
    @Binding var contentHeight: CGFloat
    let onLinkTap: (Int) -> Void

    nonisolated static let maximumContentHeight: CGFloat = 50_000

    nonisolated static func clampedHeight(_ raw: CGFloat) -> CGFloat {
        guard raw.isFinite else { return 1 }
        return min(max(raw, 1), maximumContentHeight)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let webView = WKWebView(
            frame: .zero, configuration: MailWebViewFactory.makeConfiguration(cidHandler: context.coordinator.cidHandler)
        )
        webView.navigationDelegate = context.coordinator
        webView.allowsLinkPreview = false
        webView.scrollView.isScrollEnabled = false
        webView.isOpaque = false
        Self.paint(webView, with: theme)
        context.coordinator.observeHeight(of: webView)
        context.coordinator.load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: webView)
    }

    static func paint(_ webView: WKWebView, with theme: MailHTMLTheme) {
        webView.backgroundColor = theme.backgroundColor
        webView.scrollView.backgroundColor = theme.backgroundColor
        webView.underPageBackgroundColor = theme.backgroundColor
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: MailHTMLView
        let cidHandler: MailCIDSchemeHandler
        private(set) var loadedKey: String?
        private var loadGeneration = 0
        private(set) var loadTask: Task<Void, Never>?
        private(set) var installedRulesAllowRemoteImages: Bool?
        private var heightObservation: NSKeyValueObservation?

        init(parent: MailHTMLView) {
            self.parent = parent
            cidHandler = MailCIDSchemeHandler(images: parent.inlineImages)
        }

        func observeHeight(of webView: WKWebView) {
            heightObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, change in
                guard let self, let height = change.newValue?.height else { return }
                Task { @MainActor in self.parent.contentHeight = MailHTMLView.clampedHeight(height) }
            }
        }

        func load(into webView: WKWebView) {
            cidHandler.images = parent.inlineImages
            let images = parent.inlineImages.keys.sorted()
            let key = "\(parent.allowRemoteImages)|\(parent.theme)|\(parent.html.hashValue)|\(images)"
            guard key != loadedKey else { return }
            loadedKey = key
            let theme = parent.theme
            let document = MailWebViewFactory.document(for: parent.html, allowRemoteImages: parent.allowRemoteImages,
                                                       theme: theme)
            let allowImages = parent.allowRemoteImages
            loadTask?.cancel()
            loadGeneration += 1
            let generation = loadGeneration
            if installedRulesAllowRemoteImages == allowImages {
                loadTask = nil
                MailHTMLView.paint(webView, with: theme)
                webView.loadHTMLString(document, baseURL: nil)
                return
            }
            loadTask = Task { @MainActor [weak self] in
                let rules = await MailWebViewFactory.compileRules(allowRemoteImages: allowImages)
                guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                MailWebViewFactory.installRules(rules, on: webView)
                self.installedRulesAllowRemoteImages = rules == nil ? nil : allowImages
                MailHTMLView.paint(webView, with: theme)
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
            return navigationAction.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
    }
}
#endif
