#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailHTMLSanitizerTests {
    static let corpus: [String] = try! SchoolMailFixtures.lines("xss-corpus")

    /// The same forbidden-token list as Android's `HtmlSanitizerTest` — one hard-coded
    /// list checked against every corpus vector's sanitized output, case-insensitively.
    /// `image-set` was added alongside the CSS image-loading-function check (controller
    /// ruling, 2026-09-16): the corpus now includes a `list-style: image-set(...)` vector.
    static let forbiddenTokens = [
        "<script", "javascript:", "vbscript:", "data:text", "data:image/svg", "onerror", "onload", "onclick",
        "onmouseover", "<iframe", "<object", "<embed", "<svg", "<math", "<base", "<meta", "<form",
        "<input", "<style", "<link", "<template", "<noscript", "expression(", "url(", "@import",
        "behavior", "-moz-binding", "position", "z-index", "background=", "image-set",
    ]

    @Test func neutralisesTheCorpus() {
        #expect(Self.corpus.count >= 30)
        for vector in Self.corpus {
            let html = MailHTMLSanitizer.sanitize(vector, allowRemoteImages: false).html.lowercased()
            for token in Self.forbiddenTokens {
                #expect(!html.contains(token), "'\(token)' survived in: \(vector) -> \(html)")
            }
        }
    }

    @Test func remoteImagesAreHeldBackUntilAllowed() {
        let source = "<img src=\"https://x.example/a.png\" alt=\"a\">"
        let blocked = MailHTMLSanitizer.sanitize(source, allowRemoteImages: false)
        #expect(blocked.blockedRemoteImages == 1)
        #expect(blocked.html.contains("data-remote-src=\"https://x.example/a.png\""))
        #expect(!blocked.html.contains(" src="))
        let allowed = MailHTMLSanitizer.sanitize(source, allowRemoteImages: true)
        #expect(allowed.blockedRemoteImages == 0)
        #expect(allowed.html.contains("src=\"https://x.example/a.png\""))
    }

    /// Controller ruling (2026-09-16): a sender-supplied `data-remote-src` must never survive —
    /// that attribute may only ever hold an http(s) URL the sanitizer itself held back and counted.
    @Test func senderSuppliedRemoteSrcAttributeIsIgnored() {
        let result = MailHTMLSanitizer.sanitize(
            "<img data-remote-src=\"https://track.example/hidden.gif\">",
            allowRemoteImages: false
        )
        #expect(result.blockedRemoteImages == 0)
        #expect(!result.html.contains("data-remote-src"))
    }

    /// Controller ruling (2026-09-16): the `src` value is trimmed and written back before the
    /// scheme is inspected, so a leading/trailing-whitespace `data:` URL is still recognised
    /// and kept (trimmed), matching Android's `img.attr("src", img.attr("src").trim())`.
    @Test func trimsSrcWhitespaceBeforeChecking() {
        let html = MailHTMLSanitizer.sanitize(
            "<img src=\" data:image/png;base64,iVBORw0KGgo=\">",
            allowRemoteImages: false
        ).html
        #expect(html.contains("src=\"data:image/png;base64,iVBORw0KGgo=\""))
    }

    @Test func inlineAndDataImages() {
        let html = MailHTMLSanitizer.sanitize(
            "<img src=\"cid:logo@x\"><img src=\"data:image/png;base64,iVBORw0KGgo=\"><img src=\"data:image/svg+xml;base64,PHN2Zz4=\">",
            allowRemoteImages: false
        ).html
        #expect(html.contains("src=\"tdcid:logo@x\""))
        #expect(html.contains("src=\"data:image/png;base64,iVBORw0KGgo=\""))
        #expect(!html.contains("svg+xml"))
    }

    @Test func collectsLinksWithTheirText() {
        let result = MailHTMLSanitizer.sanitize("<p><a href=\"https://www.ntust.edu.tw\">學校首頁</a></p>", allowRemoteImages: false)
        #expect(result.links == [MailLink(text: "學校首頁", href: "https://www.ntust.edu.tw")])
    }

    @Test func plainTextKeepsBlockBreaks() {
        #expect(MailHTMLSanitizer.plainText(fromHTML: "<p>a</p><p>b<br>c</p><ul><li>d</li><li>e</li></ul>") == "a\nb\nc\nd\ne")
    }

    @Test func cssFilterKeepsOnlyTheAllowlist() {
        #expect(MailCSSFilter.filter("color: red; margin-left: 4px; position: absolute") == "color: red; margin-left: 4px")
        #expect(MailCSSFilter.filter("background-image: url(x)") == nil)
        #expect(MailCSSFilter.filter("display: inline-block !important") == "display: inline-block !important")
    }

    /// Controller ruling (2026-09-16): reject `image-set`/`image()`/`cross-fade`/`element()` the
    /// same way as `url(`, so a CSS image-loading function can't be used to fetch a remote image
    /// behind the sanitizer's back.
    @Test func cssFilterRejectsImageLoadingFunctions() {
        #expect(MailCSSFilter.filter("border-image-source: image-set(\"https://t.example/p.gif\" 1x)") == nil)
        #expect(MailCSSFilter.filter("list-style: image-set('https://t.example/q.gif' 1x)") == nil)
    }

    @Test func linkifierMarksURLs() {
        let text = MailTextLinkifier.attributed("see https://www.ntust.edu.tw now")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://www.ntust.edu.tw")!])
    }
}
#endif
