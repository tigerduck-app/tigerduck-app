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

/// HTML for the web view in which every `<a href>` is `https://link.invalid/<n>`, with
/// `links[n]` holding the text and href that anchor had. Mirrors Android's
/// `LinkedHtml`/`MailHtmlDocument.rewriteLinks`. When the anchors cannot be kept in lockstep
/// with `links`, `links` is empty and no anchor has an `href` at all; see
/// `MailHTMLSanitizer.rewriteLinks`.
nonisolated struct LinkedHTML: Equatable, Sendable {
    var html: String
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
    /// Same pattern as Android's `DATA_IMAGE` regex. The MIME subtype must be followed
    /// immediately by `;` or `,` (the start of `;base64,` or of a raw `,`-separated payload),
    /// so `data:image/pngx,AAAA`, which a plain prefix check would accept, is rejected.
    private static let dataImagePattern = try! NSRegularExpression(
        pattern: "^data:image/(png|jpeg|gif|webp)[;,]",
        options: .caseInsensitive
    )

    private static func isAllowedDataImage(_ source: String) -> Bool {
        let range = NSRange(source.startIndex..., in: source)
        return dataImagePattern.firstMatch(in: source, options: [], range: range) != nil
    }

    /// `width: 5.6875in` or `height: 772px !important`, written the way `MailCSSFilter.filter`
    /// writes a declaration, in a CSS length unit. `%`, `auto`, unitless numbers and made-up
    /// units don't match.
    private static let fixedLengthPattern = try! NSRegularExpression(
        pattern: #"^(?:width|height): ([0-9]*\.?[0-9]+)(px|pt|pc|in|cm|mm|em|rem|ex|ch|vw|vh|vmin|vmax)\s*(?:!\s*important)?$"#,
        options: .caseInsensitive
    )

    /// An image's filtered `style` with a fixed `width` and `height` in one unit rewritten as
    /// that width and their `aspect-ratio`, or nil to leave it alone (#226). Not `private`:
    /// unit-tested directly. The page's `img{max-width:100%;height:auto}` narrows a wide image,
    /// but a fixed inline height outranks `height:auto`, so it would keep its height and stretch;
    /// Outlook sizes inline images this way (`width:6.25in;height:8.84in`). With the ratio, a
    /// narrowed image keeps its shape and any other keeps the sender's box, even while held back.
    /// ponytail: `546px` by `8in` still stretches, and so does an inline height beside a `width`
    /// attribute; converting absolute units to px, and reading the attribute, would cover them.
    static func keepingAspectRatio(_ style: String) -> String? {
        let declarations = style.components(separatedBy: "; ")
        let widths = declarations.filter { $0.hasPrefix("width:") }
        let heights = declarations.filter { $0.hasPrefix("height:") }
        // Exactly one of each: given two, `!important` decides which one applies.
        guard widths.count == 1, heights.count == 1,
              let width = fixedLength(widths[0]), let height = fixedLength(heights[0]),
              width.unit == height.unit else { return nil }
        let kept = declarations.filter { !$0.hasPrefix("height:") }
        return (kept + ["aspect-ratio: \(width.number) / \(height.number)"]).joined(separator: "; ")
    }

    private static func fixedLength(_ declaration: String) -> (number: String, unit: String)? {
        let range = NSRange(declaration.startIndex..., in: declaration)
        guard let match = fixedLengthPattern.firstMatch(in: declaration, options: [], range: range),
              let numberRange = Range(match.range(at: 1), in: declaration),
              let unitRange = Range(match.range(at: 2), in: declaration) else { return nil }
        let number = String(declaration[numberRange])
        guard let value = Double(number), value > 0 else { return nil }
        return (number, declaration[unitRange].lowercased())
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
                // Only this loop ever writes `data-remote-src`. The Cleaner already strips a
                // sender's copy, since the whitelist lacks it; removing it here keeps that true if
                // the whitelist changes. Mirrors Android's `img.removeAttr(REMOTE_SRC_ATTR)`.
                try image.removeAttr(remoteImageAttribute)

                if let style = keepingAspectRatio(try image.attr("style")) {
                    try image.attr("style", style)
                }

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
                // Trim and write back, as for `src`: SwiftSoup's Whitelist checks a trimmed URL but
                // keeps the original, so a space or decoded `&#x0a;` stays in the HTML and `href`:
                // `URL(string:)` fails, so no mismatch warning shows, yet WebKit follows the link.
                let href = try anchor.attr("href").trimmingCharacters(in: .whitespacesAndNewlines)
                try anchor.attr("href", href)
                // A.3: link text loses bidi controls too, same as sender names/subjects,
                // so a bidi override can't disguise what a link's visible text says.
                let text = MailTextCleaner.clean(try anchor.text())
                links.append(MailLink(text: text, href: href))
            }

            return SanitizedHTML(html: try clean.body()?.html() ?? "", blockedRemoteImages: blocked, links: links)
        } catch {
            // Fail closed: fall back to escaped plain text. Log only the error's type, never its
            // message or the mail content: mail content never leaves the device or reaches a log.
            logger.error("HTML sanitize failed, falling back to escaped plain text: \(String(describing: type(of: error)), privacy: .public)")
            let escaped = html
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return SanitizedHTML(html: "<pre>\(escaped)</pre>", blockedRemoteImages: 0, links: [])
        }
    }

    /// Rewrites every `<a href>` in sanitized `html` to `https://link.invalid/<n>`; `links[n]`
    /// holds anchor `n`'s text and original href, read off the tree this rewrites, never off
    /// `SanitizedHTML.links`. The cleaner can drop an element but keep its children, a tree no
    /// parser builds, so a reparse can shift an index. The web view reparses this output, so it
    /// is reparsed here and must yield the same anchors, href and text, in order. On a mismatch
    /// or any failure, every `href` is stripped and `links` is empty: live links never pair with
    /// `links: []`. The navigation delegate answers a tap with the index alone, never a URL, so
    /// no WebKit canonicalization quirk can misroute a tap. `.invalid` never resolves (RFC 2606).
    static func rewriteLinks(_ html: String) -> LinkedHTML {
        guard let doc = try? SwiftSoup.parseBodyFragment(html) else {
            return LinkedHTML(html: stripHrefsWithRegex(html), links: [])
        }
        doc.outputSettings().prettyPrint(pretty: false)
        guard let anchors = try? doc.select("a[href]") else {
            _ = try? doc.select("a").removeAttr("href")
            return LinkedHTML(html: (try? doc.body()?.html()) ?? stripHrefsWithRegex(html), links: [])
        }
        var links: [MailLink] = []
        for (index, anchor) in anchors.array().enumerated() {
            let text = (try? anchor.text()) ?? ""
            let href = (try? anchor.attr("href")) ?? ""
            links.append(MailLink(text: MailTextCleaner.clean(text), href: href))
            _ = try? anchor.attr("href", "https://link.invalid/\(index)")
        }
        let rewritten = (try? doc.body()?.html()) ?? html
        if let reparsed = try? SwiftSoup.parseBodyFragment(rewritten), let reanchors = try? reparsed.select("a[href]"),
           Self.hrefsAndTexts(reanchors) == Self.hrefsAndTexts(anchors) {
            return LinkedHTML(html: rewritten, links: links)
        }
        _ = try? anchors.removeAttr("href")
        return LinkedHTML(html: (try? doc.body()?.html()) ?? stripHrefsWithRegex(rewritten), links: [])
    }

    private static func hrefsAndTexts(_ anchors: Elements) -> [[String]] {
        anchors.array().map { [((try? $0.attr("href")) ?? ""), ((try? $0.text()) ?? "")] }
    }

    /// Last resort when `SwiftSoup.parseBodyFragment` failed and no tree is left to strip: removes
    /// every `href` as text, double-quoted, single-quoted or unquoted (HTML5 allows all three).
    /// HTML5's "before attribute name" state also takes `/` as a separator, so `<a/href="…">`
    /// carries a live `href`. After a quoted value no separator is needed (`<a href="a"href="b">`
    /// is two attributes), so a quote also starts a match, via a zero-width lookbehind that keeps
    /// the previous closing quote. Over-stripping is the safe side: removing an `href=` that was
    /// only text costs a few characters, missing one costs a tappable phishing link. Not `private`:
    /// unit-tested directly, since no input makes SwiftSoup's own parser fail on demand.
    static let hrefAttributePattern = try! NSRegularExpression(
        pattern: #"(?:[\s/]+|(?<=["']))href\s*=\s*("[^"]*"|'[^']*'|[^\s"'=<>`]+)"#, options: .caseInsensitive
    )

    static func stripHrefsWithRegex(_ html: String) -> String {
        let range = NSRange(html.startIndex..., in: html)
        return hrefAttributePattern.stringByReplacingMatches(in: html, range: range, withTemplate: "")
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
