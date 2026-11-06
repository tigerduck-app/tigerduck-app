import WebKit

@MainActor
final class BrowserPageUI: NSObject, WKUIDelegate {
    private let openHere: (WKNavigationAction, WKWebView) -> Void

    init(openHere: @escaping (WKNavigationAction, WKWebView) -> Void) {
        self.openHere = openHere
    }

    /// A page opens an empty window to write into; loading one here would empty this page.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for action: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        let address = action.request.url?.absoluteString ?? ""
        if !address.isEmpty, address != "about:blank" { openHere(action, webView) }
        return nil
    }

    func webView(
        _ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType, decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}
