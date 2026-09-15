#if os(iOS)
import Foundation
import SwiftSoup
import os

nonisolated struct MailLink: Codable, Hashable, Sendable {
    var text: String
    var href: String
}

nonisolated struct SanitizedHTML: Equatable, Sendable {
    var html: String
    var blockedRemoteImages: Int
    var links: [MailLink]
}

/// Appendix A.2. The sanitizer is the second line of defence; the first is the web view
/// with JavaScript off and network loads blocked (`MailWebViewFactory`).
nonisolated enum MailHTMLSanitizer {
    static let cidScheme = "tdcid"
    static let remoteImageAttribute = "data-remote-src"

    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.Sanitizer")

    static let allowedTags = [
        "a", "abbr", "b", "big", "blockquote", "br", "caption", "center", "cite", "code", "col", "colgroup",
        "dd", "del", "div", "dl", "dt", "em", "font", "h1", "h2", "h3", "h4", "h5", "h6", "hr", "i", "img",
        "ins", "kbd", "li", "ol", "p", "pre", "q", "s", "small", "span", "strike", "strong", "sub", "sup",
        "table", "tbody", "td", "tfoot", "th", "thead", "tr", "tt", "u", "ul",
    ]
    static let removedWithContent = [
        "script", "style", "head", "title", "iframe", "frame", "frameset", "object", "embed", "applet",
        "form", "input", "button", "select", "option", "textarea", "meta", "link", "base", "svg", "math",
        "audio", "video", "source", "track", "canvas", "noscript", "template",
    ]
    static let allowedAttributes: [String: [String]] = [
        ":all": ["style", "dir", "lang", "title", "align"],
        "a": ["href"],
        "img": ["src", "alt", "width", "height", "border"],
        "table": ["width", "height", "border", "cellpadding", "cellspacing", "bgcolor"],
        "td": ["width", "height", "bgcolor", "valign", "colspan", "rowspan", "nowrap"],
        "th": ["width", "height", "bgcolor", "valign", "colspan", "rowspan", "nowrap"],
        "tr": ["bgcolor", "valign"],
        "col": ["span", "width"],
        "colgroup": ["span", "width"],
        "font": ["color", "face", "size"],
        "ol": ["start", "type"],
        "ul": ["type"],
        "li": ["value"],
    ]
    /// Matches Android's `DATA_IMAGE` regex exactly: the MIME subtype must be followed
    /// immediately by `;` or `,` (the start of `;base64,` or a raw `,`-separated payload),
    /// so a bypass like `data:image/pngx,AAAA` does not pass a naive prefix check
    /// (fix round 1, 2026-09-16).
    private static let dataImagePattern = try! NSRegularExpression(
        pattern: "^data:image/(png|jpeg|gif|webp)[;,]",
        options: .caseInsensitive
    )

    private static func isAllowedDataImage(_ source: String) -> Bool {
        let range = NSRange(source.startIndex..., in: source)
        return dataImagePattern.firstMatch(in: source, options: [], range: range) != nil
    }

    static func sanitize(_ html: String, allowRemoteImages: Bool) -> SanitizedHTML {
        do {
            let dirty = try SwiftSoup.parse(html, "")
            try dirty.select(removedWithContent.joined(separator: ",")).remove()
            let clean = try Cleaner(headWhitelist: nil, bodyWhitelist: try makeWhitelist()).clean(dirty)
            clean.outputSettings().prettyPrint(pretty: false)

            for element in try clean.select("[style]") {
                if let filtered = MailCSSFilter.filter(try element.attr("style")) {
                    try element.attr("style", filtered)
                } else {
                    try element.removeAttr("style")
                }
            }

            var blocked = 0
            for image in try clean.select("img") {
                // `data-remote-src` is not in the whitelist above, so the Cleaner step already
                // stripped any sender-supplied copy of it — this call is belt-and-braces so the
                // guarantee holds even if the whitelist changes later (controller ruling,
                // 2026-09-16; mirrors Android's `img.removeAttr(REMOTE_SRC_ATTR)`). After this
                // point, `data-remote-src` is only ever written by this loop, below.
                try image.removeAttr(remoteImageAttribute)

                // Trim and write the value back before inspecting it, so a source like
                // `src=" data:image/png;..."` is still recognised (controller ruling,
                // 2026-09-16; mirrors Android's `img.attr("src", img.attr("src").trim())`).
                let source = try image.attr("src").trimmingCharacters(in: .whitespacesAndNewlines)
                try image.attr("src", source)
                let lowered = source.lowercased()
                if lowered.hasPrefix("cid:") {
                    try image.attr("src", "\(cidScheme):\(source.dropFirst(4))")
                } else if isAllowedDataImage(source) {
                    continue
                } else if lowered.hasPrefix("https://") || lowered.hasPrefix("http://") {
                    if !allowRemoteImages {
                        try image.removeAttr("src")
                        try image.attr(remoteImageAttribute, source)
                        blocked += 1
                    }
                } else {
                    try image.removeAttr("src")
                }
            }

            var links: [MailLink] = []
            for anchor in try clean.select("a[href]") {
                // Trim and write the value back before collecting it, mirroring the `src`
                // ruling above. SwiftSoup's Whitelist validates a URL attribute's *trimmed*
                // value but by default writes out the *original* bytes, so a leading/trailing
                // space — or a decoded `&#x0a;`/`&#x09;` control character — would otherwise
                // survive into both the serialized HTML and `href`, breaking `URL(string:)`
                // downstream and silently disabling the A.4 link-mismatch warning while
                // WebKit still navigates the untrimmed link (fix round 1, 2026-09-16).
                let href = try anchor.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                try anchor.attr("href", href)
                // A.3: link text loses bidi controls too, same as sender names/subjects,
                // so a bidi override can't disguise what a link's visible text says.
                let text = MailTextCleaner.clean(try anchor.text())
                links.append(MailLink(text: text, href: href))
            }

            return SanitizedHTML(html: try clean.body()?.html() ?? "", blockedRemoteImages: blocked, links: links)
        } catch {
            // Fail closed: fall back to escaped plain text. Log only the error's type, never
            // its message or the mail content — mail content never leaves the device or reaches
            // a log (fix round 1, 2026-09-16).
            logger.error("HTML sanitize failed, falling back to escaped plain text: \(String(describing: type(of: error)), privacy: .public)")
            let escaped = html
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return SanitizedHTML(html: "<pre>\(escaped)</pre>", blockedRemoteImages: 0, links: [])
        }
    }

    private static func makeWhitelist() throws -> Whitelist {
        let whitelist = Whitelist.none()
        for tag in allowedTags { _ = try whitelist.addTags(tag) }
        for (tag, attributes) in allowedAttributes {
            for attribute in attributes { _ = try whitelist.addAttributes(tag, attribute) }
        }
        _ = try whitelist.addProtocols("a", "href", "http", "https", "mailto")
        return whitelist
    }

    /// The plain-text view of an HTML-only mail: block elements become line breaks.
    static func plainText(fromHTML html: String) -> String {
        guard let document = try? SwiftSoup.parse(html, ""), let body = document.body() else { return html }
        var output = ""
        appendText(of: body, to: &output)
        return output
            .replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let blockTags: Set<String> = [
        "p", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote", "pre", "table",
        "ul", "ol", "dl", "dt", "dd", "hr", "center",
    ]

    private static func appendText(of node: Node, to output: inout String) {
        for child in node.getChildNodes() {
            if let text = child as? TextNode {
                output += text.text()
            } else if let element = child as? Element {
                let tag = element.tagName().lowercased()
                if tag == "br" {
                    output += "\n"
                    continue
                }
                let isBlock = blockTags.contains(tag)
                if isBlock, !output.isEmpty, !output.hasSuffix("\n") { output += "\n" }
                appendText(of: element, to: &output)
                if isBlock, !output.hasSuffix("\n") { output += "\n" }
            }
        }
    }
}
#endif
