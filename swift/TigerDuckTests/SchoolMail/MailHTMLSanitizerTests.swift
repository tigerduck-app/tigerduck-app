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

    /// Fix round 1 (2026-09-16, minor): the data-image check requires the MIME subtype to be
    /// followed immediately by `;` or `,`, matching Android's `DATA_IMAGE` regex exactly — a
    /// naive prefix check would let a lookalike like `data:image/pngx,...` through.
    @Test func dataImageCheckRequiresExactMimeBoundary() {
        let html = MailHTMLSanitizer.sanitize("<img src=\"data:image/pngx,AAAA\">", allowRemoteImages: false).html
        #expect(!html.contains(" src="))
        #expect(!html.contains("data:image/pngx"))
    }

    @Test func collectsLinksWithTheirText() {
        let result = MailHTMLSanitizer.sanitize("<p><a href=\"https://www.ntust.edu.tw\">學校首頁</a></p>", allowRemoteImages: false)
        #expect(result.links == [MailLink(text: "學校首頁", href: "https://www.ntust.edu.tw")])
    }

    /// Ported from Android's `HtmlSanitizerTest` ("links are extracted with their visible
    /// text"), fix round 1 (2026-09-16, minor): an evil href behind NTUST-looking visible
    /// text, plus a `mailto:` link, so a sanitizer that dropped everything couldn't
    /// accidentally pass the negative tests.
    @Test func linksKeepEvilHrefsBehindTrustedLookingText() {
        let result = MailHTMLSanitizer.sanitize(
            "<a href=\"https://evil.example/login\">https://www.ntust.edu.tw</a> <a href=\"mailto:a@b.tw\">mail</a>",
            allowRemoteImages: false
        )
        #expect(result.links == [
            MailLink(text: "https://www.ntust.edu.tw", href: "https://evil.example/login"),
            MailLink(text: "mail", href: "mailto:a@b.tw"),
        ])
    }

    /// Fix round 1 (2026-09-16, IMPORTANT): SwiftSoup's `Whitelist` validates a URL
    /// attribute's *trimmed* value but by default writes out the *original* untrimmed bytes.
    /// Left unfixed, `href=" https://evil.example/login"` (or an entity-decoded `&#x0a;`/
    /// `&#x09;` control-character prefix) would survive into both `links[].href` and the
    /// output HTML — `URL(string:)` on that returns nil, silently disabling the A.4
    /// link-mismatch warning, while WebKit still navigates the untrimmed link. The fix
    /// mirrors the `src` handling above: trim and write the value back before collecting it.
    @Test func trimsHrefWhitespaceBeforeChecking() {
        for prefix in [" ", "\t", "\n", "&#x0a;", "&#x09;"] {
            let html = "<a href=\"\(prefix)https://www.ntust.edu.tw\">x</a>"
            let result = MailHTMLSanitizer.sanitize(html, allowRemoteImages: false)
            #expect(result.links == [MailLink(text: "x", href: "https://www.ntust.edu.tw")], "prefix \(prefix.debugDescription)")
            #expect(result.html.contains("href=\"https://www.ntust.edu.tw\""), "prefix \(prefix.debugDescription)")
        }
    }

    /// Fix round 1 (2026-09-16, minor): link text loses bidi controls too, the same as
    /// sender names/subjects/attachment names (Task 3's `MailTextCleaner`), mirroring
    /// Android's `TextCleaning.clean(it.text())` — so a bidi override can't disguise what a
    /// link's visible text says.
    @Test func linkTextLosesBidiControls() {
        let result = MailHTMLSanitizer.sanitize(
            "<a href=\"https://example.tw\">invoice\u{202E}fdp.exe</a>",
            allowRemoteImages: false
        )
        #expect(result.links == [MailLink(text: "invoicefdp.exe", href: "https://example.tw")])
    }

    /// Ported from Android's `HtmlSanitizerTest` ("formatting and safe styles are kept"),
    /// fix round 1 (2026-09-16, minor): a positive test so a sanitizer that dropped
    /// everything couldn't accidentally pass the negative/corpus tests.
    @Test func formattingAndSafeStylesAreKept() {
        let html = MailHTMLSanitizer.sanitize(
            "<p style=\"color: red; position: fixed\">Hi <b>there</b></p><table border=\"1\"><tr><td colspan=\"2\">x</td></tr></table>",
            allowRemoteImages: false
        ).html
        #expect(html.contains("<b>there</b>"))
        #expect(html.contains("style=\"color: red\""))
        #expect(html.contains("colspan=\"2\""))
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


    // MARK: rewriteLinks and its fail-closed strip
    //
    // `rewriteLinks` is what stands between the web view and a live sender-supplied URL: every
    // `<a href>` becomes `https://link.invalid/<n>` and the real href is handed back out of
    // band, so a tap is answered by index and WebKit never holds the attacker's URL. When the
    // anchors can't be kept in lockstep with that list, nothing is guessed — every `href` is
    // stripped. Until now only the happy path had any coverage at all.

    @Test func rewriteLinksReplacesEveryHrefAndReportsTheOriginals() {
        let result = MailHTMLSanitizer.rewriteLinks(
            "<p><a href=\"https://evil.example/login\">ntust.edu.tw</a> and <a href=\"mailto:cc@mail.ntust.edu.tw\">mail</a></p>"
        )
        #expect(result.links == [
            MailLink(text: "ntust.edu.tw", href: "https://evil.example/login"),
            MailLink(text: "mail", href: "mailto:cc@mail.ntust.edu.tw"),
        ])
        #expect(result.html.contains("https://link.invalid/0"))
        #expect(result.html.contains("https://link.invalid/1"))
        #expect(!result.html.contains("evil.example"))
        #expect(!result.html.contains("mailto:"))
    }

    /// The form the `\s+`-only pattern walked past: HTML5's "before attribute name" state
    /// treats `/` as a separator, so this `href` is real and live, and the tokenizer needs no
    /// separator at all after a quoted value.
    @Test(arguments: [
        "<a/href=\"https://evil.example\">x</a>",
        "<a//href='https://evil.example'>x</a>",
        "<a/href=https://evil.example>x</a>",
        "<a href=\"https://ok.example\"href=\"https://evil.example\">x</a>",
        "<a\nhref=\"https://evil.example\">x</a>",
        "<a href = \"https://evil.example\" >x</a>",
        "<a HREF=\"https://evil.example\">x</a>",
    ])
    func failClosedStripLeavesNoLiveHref(markup: String) {
        let stripped = MailHTMLSanitizer.stripHrefsWithRegex(markup)
        #expect(!stripped.lowercased().contains("href"))
        #expect(!stripped.contains("evil.example"))
    }

    /// The strip must not eat the rest of the tag, or the fallback would render as gibberish.
    @Test func failClosedStripKeepsEverythingThatIsNotAnHref() {
        let stripped = MailHTMLSanitizer.stripHrefsWithRegex(
            "<p>hi <a/href=\"https://evil.example\" title=\"open\">ntust.edu.tw</a></p>"
        )
        #expect(stripped == "<p>hi <a title=\"open\">ntust.edu.tw</a></p>")
    }

    /// `LinkedHTML`'s contract in one assertion: the html it carries never holds a live href
    /// while `links` claims there is nothing to tap. Run over the whole XSS corpus plus the
    /// anchor shapes above, so a future change to either branch has to keep it true.
    @Test func rewriteLinksNeverLeavesALiveHrefBehind() {
        let extra = [
            "<a/href=\"https://evil.example\">x</a>",
            "<a href=\"https://ok.example\"href=\"https://evil.example\">x</a>",
            "<a href=\"https://evil.example\">x<div>y</div></a>",
            "<a href=\"https://evil.example\"><a href=\"https://evil2.example\">y</a></a>",
            "<table><a href=\"https://evil.example\">x</a></table>",
            "<a href=\"https://evil.example\">x\u{0000}y</a>",
        ]
        for vector in Self.corpus + extra {
            let result = MailHTMLSanitizer.rewriteLinks(MailHTMLSanitizer.sanitize(vector, allowRemoteImages: false).html)
            for href in Self.hrefValues(in: result.html) {
                #expect(href.hasPrefix("https://link.invalid/"), "live href '\(href)' survived: \(vector)")
            }
            if result.links.isEmpty {
                #expect(!result.html.lowercased().contains("href"), "empty links but an href remains: \(vector)")
            }
        }
    }

    private static let hrefValuePattern = try! NSRegularExpression(
        pattern: #"href\s*=\s*"([^"]*)""#, options: .caseInsensitive
    )

    private static func hrefValues(in html: String) -> [String] {
        hrefValuePattern.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { range in String(html[range]) }
        }
    }

    // MARK: How tall the sender may make the message view

    /// `height` and `min-height` are allowed CSS on purpose — a mail that sets them renders as
    /// it was written — but that also means the sender writes `scrollView.contentSize.height`,
    /// which the message screen puts straight into `.frame(height:)`. It used to have only a
    /// lower bound, so the size asked for was whatever the CSS said.
    @Test func theRenderedHeightIsClampedAtBothEnds() {
        #expect(MailCSSFilter.allowedProperties.contains("height"))
        #expect(MailCSSFilter.allowedProperties.contains("min-height"))
        #expect(MailHTMLView.clampedHeight(600) == 600)
        #expect(MailHTMLView.clampedHeight(0) == 1)
        #expect(MailHTMLView.clampedHeight(-5) == 1)
        #expect(MailHTMLView.clampedHeight(9_999_999) == MailHTMLView.maximumContentHeight)
        #expect(MailHTMLView.clampedHeight(.infinity) == 1)
        #expect(MailHTMLView.clampedHeight(.nan) == 1)
    }
}
#endif
