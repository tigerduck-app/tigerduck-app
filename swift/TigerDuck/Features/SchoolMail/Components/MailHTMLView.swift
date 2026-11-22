#if os(iOS)
import SwiftUI
import WebKit

struct MailHTMLView: UIViewRepresentable {
    let html: String
    let linkCount: Int
    let inlineImages: [String: MailInlineImage]
    let allowRemoteImages: Bool
    var theme: MailHTMLTheme = .app
    var textZoom = PageZoom.standard
    @Binding var contentHeight: CGFloat
    let onLinkTap: (Int) -> Void
    /// False when a load starts, true once it finishes or fails.
    var onLoadedChange: (Bool) -> Void = { _ in }
    /// The `src` of an image outside any link, as the page has it.
    var onImageTap: (String) -> Void = { _ in }

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
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        webView.addGestureRecognizer(tap)
        context.coordinator.load(into: webView)
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.load(into: webView)
        context.coordinator.applyTextZoom(to: webView)
    }

    static func paint(_ webView: WKWebView, with theme: MailHTMLTheme) {
        webView.backgroundColor = theme.backgroundColor
        webView.scrollView.backgroundColor = theme.backgroundColor
        webView.underPageBackgroundColor = theme.backgroundColor
    }

    final class Coordinator: NSObject, WKNavigationDelegate, UIGestureRecognizerDelegate {
        var parent: MailHTMLView
        let cidHandler: MailCIDSchemeHandler
        private(set) var loadedKey: String?
        private var loadGeneration = 0
        /// The navigation the progress waits for; a replaced one may still report its cancellation.
        private var currentNavigation: WKNavigation?
        private(set) var loadTask: Task<Void, Never>?
        private(set) var installedRulesAllowRemoteImages: Bool?
        private var heightObservation: NSKeyValueObservation?
        private var zoomOnPage = PageZoom.standard

        init(parent: MailHTMLView) {
            self.parent = parent
            cidHandler = MailCIDSchemeHandler(images: parent.inlineImages)
        }

        /// `[weak self]` keeps the observation from retaining the coordinator (the coordinator
        /// owns the observation, so a strong capture would be a cycle). The weak binding is
        /// resolved *here*, in the observation callback, rather than inside the `Task`: a `weak`
        /// capture is a mutable variable, and reading one from concurrently-executing code is an
        /// error in the Swift 6 language mode. `guard let self` turns it into an immutable
        /// strong reference the `Task` can capture, which is dropped again as soon as that hop
        /// finishes — the observation itself still holds nothing.
        func observeHeight(of webView: WKWebView) {
            heightObservation = webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak webView] _, _ in
                guard let self, let webView else { return }
                Task { @MainActor in self.fitHeight(of: webView) }
            }
        }

        func load(into webView: WKWebView) {
            cidHandler.images = parent.inlineImages
            let images = parent.inlineImages.keys.sorted()
            let key = "\(parent.allowRemoteImages)|\(parent.theme)|\(parent.html.hashValue)|\(images)"
            guard key != loadedKey else { return }
            loadedKey = key
            // Outside the view update this runs in.
            Task { @MainActor [weak self] in self?.parent.onLoadedChange(false) }
            let theme = parent.theme
            zoomOnPage = parent.textZoom
            let document = MailWebViewFactory.document(for: parent.html, allowRemoteImages: parent.allowRemoteImages,
                                                       theme: theme, textZoom: zoomOnPage)
            let allowImages = parent.allowRemoteImages
            loadTask?.cancel()
            currentNavigation = nil
            loadGeneration += 1
            let generation = loadGeneration
            if installedRulesAllowRemoteImages == allowImages {
                loadTask = nil
                MailHTMLView.paint(webView, with: theme)
                currentNavigation = webView.loadHTMLString(document, baseURL: nil)
                return
            }
            loadTask = Task { @MainActor [weak self] in
                let rules = await MailWebViewFactory.compileRules(allowRemoteImages: allowImages)
                guard let self, !Task.isCancelled, generation == self.loadGeneration else { return }
                MailWebViewFactory.installRules(rules, on: webView)
                self.installedRulesAllowRemoteImages = rules == nil ? nil : allowImages
                MailHTMLView.paint(webView, with: theme)
                self.currentNavigation = webView.loadHTMLString(document, baseURL: nil)
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            finish(navigation, in: webView)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            finish(navigation, in: webView)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            finish(navigation, in: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            currentNavigation = nil
            parent.onLoadedChange(true)
        }

        private func finish(_ navigation: WKNavigation?, in webView: WKWebView) {
            guard let navigation, navigation === currentNavigation else { return }
            currentNavigation = nil
            parent.onLoadedChange(true)
            fitHeight(of: webView)
        }

        func applyTextZoom(to webView: WKWebView) {
            guard parent.textZoom != zoomOnPage else { return }
            fitHeight(of: webView)
        }

        /// Sets the page's text size and the height to the document's, which a smaller size or
        /// a shorter page brings down too.
        func fitHeight(of webView: WKWebView) {
            let zoom = parent.textZoom
            zoomOnPage = zoom
            let generation = loadGeneration
            Task { @MainActor [weak self] in
                let height = try? await webView.callAsyncJavaScript(
                    MailWebViewFactory.zoomAndMeasure, arguments: ["zoom": zoom], in: nil, contentWorld: .defaultClient
                ) as? Double
                guard let self, let height, generation == self.loadGeneration else { return }
                self.parent.contentHeight = MailHTMLView.clampedHeight(height.rounded(.up))
            }
        }

        /// WebKit's own taps, a link's among them, still run.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

        @objc func tapped(_ recognizer: UITapGestureRecognizer) {
            guard let webView = recognizer.view as? WKWebView else { return }
            let point = recognizer.location(in: webView.scrollView)
            Task { @MainActor [weak self] in
                guard let source = await Self.imageSource(at: point, in: webView) else { return }
                self?.parent.onImageTap(source)
            }
        }

        /// `point` is in the scroll view's content, the page's coordinates at the page's scale of 1.
        static func imageSource(at point: CGPoint, in webView: WKWebView) async -> String? {
            let found = try? await webView.callAsyncJavaScript(
                MailWebViewFactory.imageAtPoint, arguments: ["x": Double(point.x), "y": Double(point.y)],
                in: nil, contentWorld: .defaultClient
            )
            return found as? String
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
