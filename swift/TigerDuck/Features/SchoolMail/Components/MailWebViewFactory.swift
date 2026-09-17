#if os(iOS)
import Foundation
import WebKit
import os

/// The locked-down WKWebView of design doc §9.3: no JavaScript, a non-persistent store,
/// every network load blocked by a content rule (images only after "載入圖片"), inline
/// `cid:` images from a custom scheme, and a CSP as a second layer.
@MainActor
enum MailWebViewFactory {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.WebView")

    /// Exactly what `MailHTMLSanitizer.rewriteLinks` emits: `https://link.invalid/<decimal
    /// index>`, no leading zeros, no userinfo/port/query/fragment, nothing else. Anything that
    /// doesn't match this precisely fails closed rather than being treated as some link
    /// (message-screen dispatch, 2026-09-16 addition 1). `\z` (absolute end), not `$` — ICU's
    /// `$` also matches immediately before a trailing line terminator, which would let
    /// `"https://link.invalid/0\n"` slip through as index 0 (fix round 1, minor 10).
    private static let linkIndexPattern = try! NSRegularExpression(pattern: #"^https://link\.invalid/(0|[1-9][0-9]*)\z"#)

    /// Returns the link index only for the exact synthetic form, in range `[0, linkCount)`.
    static func parseLinkIndex(_ absoluteString: String, linkCount: Int) -> Int? {
        let range = NSRange(absoluteString.startIndex..., in: absoluteString)
        guard let match = linkIndexPattern.firstMatch(in: absoluteString, range: range),
              let numberRange = Range(match.range(at: 1), in: absoluteString),
              let index = Int(absoluteString[numberRange]), index >= 0, index < linkCount else { return nil }
        return index
    }

    static func makeConfiguration(inlineImages: [String: MailInlineImage]) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = []
        configuration.setURLSchemeHandler(MailCIDSchemeHandler(images: inlineImages), forURLScheme: MailHTMLSanitizer.cidScheme)
        return configuration
    }

    static func contentRules(allowRemoteImages: Bool) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^\(MailHTMLSanitizer.cidScheme):"], "action": ["type": "ignore-previous-rules"]],
            ["trigger": ["url-filter": "^data:"], "action": ["type": "ignore-previous-rules"]],
        ]
        if allowRemoteImages {
            rules.append(["trigger": ["url-filter": "^https?://", "resource-type": ["image"]],
                          "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Installed before every load. If compiling fails, the CSP still blocks remote loads; the
    /// failure's type is logged (never mail content, mirroring `MailHTMLSanitizer`'s own logger
    /// — fix round 1, minor 11) so a silently-degraded CSP-only mode is at least visible.
    static func installRules(on webView: WKWebView, allowRemoteImages: Bool) async {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        let identifier = allowRemoteImages ? "school-mail-images" : "school-mail-block-all"
        do {
            if let list = try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: contentRules(allowRemoteImages: allowRemoteImages)
            ) {
                controller.add(list)
            }
        } catch {
            logger.error("Mail content rule compile failed, CSP still blocks remote loads: \(String(describing: type(of: error)), privacy: .public)")
        }
    }

    /// White "paper" in both themes (§9.3): senders design mail for white backgrounds.
    static func document(for bodyHTML: String, allowRemoteImages: Bool) -> String {
        let imageSources = allowRemoteImages ? "tdcid: data: https: http:" : "tdcid: data:"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>html,body{margin:0;padding:12px;background:#ffffff;color:#000000;font:-apple-system-body;overflow-wrap:anywhere;}img{max-width:100%;height:auto;}table{max-width:100%;}</style>
        </head><body>\(bodyHTML)</body></html>
        """
    }
}

/// Serves `tdcid:` URLs (the sanitizer's rewrite of `cid:`) from the fetched parts.
final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler {
    private let images: [String: MailInlineImage]

    init(images: [String: MailInlineImage]) {
        self.images = images
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL))
            return
        }
        let raw = String(url.absoluteString.dropFirst("\(MailHTMLSanitizer.cidScheme):".count))
        let cid = raw.removingPercentEncoding ?? raw
        guard let image = images[cid] else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        task.didReceive(URLResponse(url: url, mimeType: image.mimeType, expectedContentLength: image.data.count, textEncodingName: nil))
        task.didReceive(image.data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}
#endif
