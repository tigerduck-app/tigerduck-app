#if os(iOS)
import Foundation
import WebKit
import os
import UIKit

nonisolated struct MailHTMLTheme: Equatable, Hashable, Sendable {
    var background: UInt32
    var foreground: UInt32
    var link: UInt32
    var isDark: Bool

    static let app = MailHTMLTheme(background: 0x000000, foreground: 0xFFFFFF, link: 0x9E9EFF, isDark: true)

    static let light = MailHTMLTheme(background: 0xFFFFFF, foreground: 0x000000, link: 0x0000EE, isDark: false)

    var backgroundCSS: String { Self.css(background) }
    var foregroundCSS: String { Self.css(foreground) }
    var backgroundColor: UIColor { Self.uiColor(background) }

    static func css(_ rgb: UInt32) -> String { String(format: "#%06x", rgb & 0xFFFFFF) }

    private static func uiColor(_ rgb: UInt32) -> UIColor {
        UIColor(red: CGFloat((rgb >> 16) & 0xFF) / 255, green: CGFloat((rgb >> 8) & 0xFF) / 255,
                blue: CGFloat(rgb & 0xFF) / 255, alpha: 1)
    }
}

@MainActor
enum MailWebViewFactory {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.WebView")

    /// Matches only the form `MailHTMLSanitizer.rewriteLinks` emits: `https://link.invalid/<decimal
    /// index>`, no leading zeros, no userinfo, port, query or fragment. Anything else fails
    /// closed rather than being treated as some link. `\z` (absolute end), not `$`: ICU's `$`
    /// also matches before a trailing line terminator, which would let
    /// `"https://link.invalid/0\n"` slip through as index 0.
    private static let linkIndexPattern = try! NSRegularExpression(pattern: #"^https://link\.invalid/(0|[1-9][0-9]*)\z"#)

    static func parseLinkIndex(_ absoluteString: String, linkCount: Int) -> Int? {
        let range = NSRange(absoluteString.startIndex..., in: absoluteString)
        guard let match = linkIndexPattern.firstMatch(in: absoluteString, range: range),
              let numberRange = Range(match.range(at: 1), in: absoluteString),
              let index = Int(absoluteString[numberRange]), index >= 0, index < linkCount else { return nil }
        return index
    }

    static func makeConfiguration(cidHandler: MailCIDSchemeHandler) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.dataDetectorTypes = []
        configuration.setURLSchemeHandler(cidHandler, forURLScheme: MailHTMLSanitizer.cidScheme)
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

    static func compileRules(allowRemoteImages: Bool) async -> WKContentRuleList? {
        let identifier = allowRemoteImages ? "school-mail-images" : "school-mail-block-all"
        do {
            return try await WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: contentRules(allowRemoteImages: allowRemoteImages)
            )
        } catch {
            logger.error("Mail content rule compile failed, CSP still blocks remote loads: \(String(describing: type(of: error)), privacy: .public)")
            return nil
        }
    }

    /// Replaces whatever rule list the web view had with `list`. Every list goes first: a
    /// `block-all` list left installed beside an `images` one keeps blocking, because
    /// `ignore-previous-rules` does not reach across lists.
    static func installRules(_ list: WKContentRuleList?, on webView: WKWebView) {
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        if let list { controller.add(list) }
    }

    static func document(for bodyHTML: String, allowRemoteImages: Bool, theme: MailHTMLTheme = .app) -> String {
        let imageSources = allowRemoteImages ? "tdcid: data: https: http:" : "tdcid: data:"
        let scheme = theme.isDark ? "dark" : "light"
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src \(imageSources); style-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>:root{color-scheme:\(scheme);}html,body{margin:0;padding:12px;background:\(theme.backgroundCSS);color:\(theme.foregroundCSS);font:-apple-system-body;overflow-wrap:anywhere;}img{max-width:100%;height:auto;}table{max-width:100%;}</style>
        </head><body>\(bodyHTML)</body></html>
        """
    }
}

final class MailCIDSchemeHandler: NSObject, WKURLSchemeHandler {
    var images: [String: MailInlineImage]

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
