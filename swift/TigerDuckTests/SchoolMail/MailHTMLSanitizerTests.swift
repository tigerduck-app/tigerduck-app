#if os(iOS)
import Foundation
import Testing
import UIKit
import WebKit
@testable import TigerDuck

struct MailHTMLSanitizerTests {
    static let corpus: [String] = try! SchoolMailFixtures.lines("xss-corpus")

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

    @Test func senderSuppliedRemoteSrcAttributeIsIgnored() {
        let result = MailHTMLSanitizer.sanitize(
            "<img data-remote-src=\"https://track.example/hidden.gif\">",
            allowRemoteImages: false
        )
        #expect(result.blockedRemoteImages == 0)
        #expect(!result.html.contains("data-remote-src"))
    }

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

    @Test func dataImageCheckRequiresExactMimeBoundary() {
        let html = MailHTMLSanitizer.sanitize("<img src=\"data:image/pngx,AAAA\">", allowRemoteImages: false).html
        #expect(!html.contains(" src="))
        #expect(!html.contains("data:image/pngx"))
    }

    @Test func aFixedImageBoxBecomesAWidthAndARatio() {
        let outlook = MailHTMLSanitizer.sanitize(
            "<img src=\"cid:poster@x\" width=\"546\" height=\"772\" style=\"width:5.6875in;height:8.0416in\">",
            allowRemoteImages: false
        ).html
        #expect(outlook.contains("style=\"width: 5.6875in; aspect-ratio: 5.6875 / 8.0416\""))
        let heldBack = MailHTMLSanitizer.sanitize(
            "<img src=\"https://x.example/p.png\" style=\"width:600px;height:848px\">",
            allowRemoteImages: false
        ).html
        #expect(heldBack.contains("style=\"width: 600px; aspect-ratio: 600 / 848\""))
        #expect(MailHTMLSanitizer.keepingAspectRatio("display: block; width: 3000PX; height: 1000px !important")
            == "display: block; width: 3000PX; aspect-ratio: 3000 / 1000")
    }

    @Test(arguments: [
        "height: 40px",
        "height: 40px; width: auto",
        "width: 100%; height: 2px",
        "width: 546px; height: 8in",
        "width: 546px; width: 100%; height: 772px",
        "height: auto !important; width: 600px; height: 300px",
        "width: 600foo; height: 300foo",
        "width: 0px; height: 24px",
    ])
    func otherImageSizesAreLeftAlone(style: String) {
        #expect(MailHTMLSanitizer.keepingAspectRatio(style) == nil)
    }

    @MainActor
    @Test(arguments: [375.0, 1280.0])
    func aFixedImageBoxKeepsItsRatioOnThePage(pageWidth: Double) async throws {
        let size = CGSize(width: 546, height: 772)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let png = UIGraphicsImageRenderer(size: size, format: format).pngData { context in
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        let box = "style=\"width:5.6875in;height:8.0416in\""
        let html = MailHTMLSanitizer.sanitize(
            "<img src=\"data:image/png;base64,\(png.base64EncodedString())\" \(box)><img src=\"https://x.example/p.png\" \(box)>",
            allowRemoteImages: false
        ).html

        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: pageWidth, height: 800))
        let webView = WKWebView(frame: window.bounds)
        window.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        webView.loadHTMLString(MailWebViewFactory.document(for: html, allowRemoteImages: false), baseURL: nil)

        let boxes = await Self.imageBoxes(in: webView, count: 2)
        #expect(boxes.count == 2)
        for box in boxes {
            #expect(abs(box.width / box.height - size.width / size.height) < 0.005, "\(box)")
            if pageWidth < size.width {
                #expect(box.width < pageWidth, "narrowed to the page: \(box)")
            } else {
                #expect(abs(box.width - size.width) < 0.5 && abs(box.height - size.height) < 0.5, "the sender's box: \(box)")
            }
        }
    }

    @MainActor
    private static func imageBoxes(in webView: WKWebView, count: Int) async -> [CGSize] {
        let probe = """
            document.readyState == "complete" && document.images.length == \(count)
                ? JSON.stringify(Array.from(document.images, i => { const r = i.getBoundingClientRect(); return [r.width, r.height]; }))
                : ""
            """
        for _ in 0..<200 {
            if let json = try? await webView.evaluateJavaScript(probe) as? String, !json.isEmpty,
               let pairs = try? JSONDecoder().decode([[Double]].self, from: Data(json.utf8)) {
                return pairs.map { CGSize(width: $0[0], height: $0[1]) }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("the page never finished loading")
        return []
    }

    @Test func collectsLinksWithTheirText() {
        let result = MailHTMLSanitizer.sanitize("<p><a href=\"https://www.ntust.edu.tw\">學校首頁</a></p>", allowRemoteImages: false)
        #expect(result.links == [MailLink(text: "學校首頁", href: "https://www.ntust.edu.tw")])
    }

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

    /// SwiftSoup's `Whitelist` validates a URL attribute's trimmed value but by default writes
    /// out the original untrimmed bytes. Without trimming, `href=" https://evil.example/login"`
    /// (or an entity-decoded `&#x0a;` or `&#x09;` prefix) would reach both `links[].href` and the
    /// output HTML. `URL(string:)` returns nil for it, silently disabling the link-mismatch
    /// warning, while WebKit still navigates the untrimmed link. Like the `src` handling above,
    /// the sanitizer trims the value and writes it back before collecting it.
    @Test func trimsHrefWhitespaceBeforeChecking() {
        for prefix in [" ", "\t", "\n", "&#x0a;", "&#x09;"] {
            let html = "<a href=\"\(prefix)https://www.ntust.edu.tw\">x</a>"
            let result = MailHTMLSanitizer.sanitize(html, allowRemoteImages: false)
            #expect(result.links == [MailLink(text: "x", href: "https://www.ntust.edu.tw")], "prefix \(prefix.debugDescription)")
            #expect(result.html.contains("href=\"https://www.ntust.edu.tw\""), "prefix \(prefix.debugDescription)")
        }
    }

    @Test func linkTextLosesBidiControls() {
        let result = MailHTMLSanitizer.sanitize(
            "<a href=\"https://example.tw\">invoice\u{202E}fdp.exe</a>",
            allowRemoteImages: false
        )
        #expect(result.links == [MailLink(text: "invoicefdp.exe", href: "https://example.tw")])
    }

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

    @Test func plainTextOfHTMLNestedFarDeeperThanTheCapKeepsItsText() {
        let html = String(repeating: "<div>", count: 10_000) + "deep" + String(repeating: "</div>", count: 10_000)
        #expect(MailHTMLSanitizer.plainText(fromHTML: html) == "deep")
    }

    @Test(arguments: [("<div>", "</div>"), ("<span>", "</span>"), ("<blockquote>", "</blockquote>"), ("<ul><li>", "</li></ul>")])
    func htmlNestedFarDeeperThanTheCapIsCleanedToTheCap(open: String, close: String) {
        let html = String(repeating: open, count: 10_000) + "deep" + String(repeating: close, count: 10_000)
        let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: false).html
        let levels = open.filter { $0 == "<" }.count
        #expect(sanitized.components(separatedBy: open).count - 1 == AppConstants.maximumHTMLDepth / levels)
        #expect(sanitized.contains("deep"))
        #expect(MailHTMLSanitizer.rewriteLinks(sanitized).html.contains("deep"))
    }

    @Test func anElementPastTheCapIsCleanedToItsText() {
        for (wrappers, written) in [(AppConstants.maximumHTMLDepth - 1, "<div><b>a</b></div>"), (AppConstants.maximumHTMLDepth, "<div>a</div>")] {
            let html = String(repeating: "<div>", count: wrappers) + "<b>a</b>" + String(repeating: "</div>", count: wrappers)
            #expect(MailHTMLSanitizer.sanitize(html, allowRemoteImages: false).html.contains(written), "\(wrappers) wrappers")
        }
    }

    @Test func pastTheCapTheTextOfARemovedElementStaysOut() {
        let wrappers = AppConstants.maximumHTMLDepth
        let html = String(repeating: "<div>", count: wrappers) + "<span><noscript>hidden</noscript>visible</span>"
            + String(repeating: "</div>", count: wrappers)
        let sanitized = MailHTMLSanitizer.sanitize(html, allowRemoteImages: false).html
        #expect(sanitized.contains("<div>visible</div>"))
        #expect(!sanitized.contains("hidden"))
    }

    @Test func plainTextPastTheCapIsTheElementsText() {
        for (wrappers, written) in [(AppConstants.maximumHTMLDepth - 1, "a\nb"), (AppConstants.maximumHTMLDepth, "a b")] {
            let html = String(repeating: "<div>", count: wrappers) + "<p>a<br>b</p>" + String(repeating: "</div>", count: wrappers)
            #expect(MailHTMLSanitizer.plainText(fromHTML: html) == written, "\(wrappers) wrappers")
        }
    }

    @Test func cssFilterKeepsOnlyTheAllowlist() {
        #expect(MailCSSFilter.filter("color: red; margin-left: 4px; position: absolute") == "color: red; margin-left: 4px")
        #expect(MailCSSFilter.filter("background-image: url(x)") == nil)
        #expect(MailCSSFilter.filter("display: inline-block !important") == "display: inline-block !important")
    }

    @Test func cssFilterRejectsImageLoadingFunctions() {
        #expect(MailCSSFilter.filter("border-image-source: image-set(\"https://t.example/p.gif\" 1x)") == nil)
        #expect(MailCSSFilter.filter("list-style: image-set('https://t.example/q.gif' 1x)") == nil)
    }

    @Test func linkifierMarksURLs() {
        let text = MailTextLinkifier.attributed("see https://www.ntust.edu.tw now")
        let links = text.runs.compactMap(\.link)
        #expect(links == [URL(string: "https://www.ntust.edu.tw")!])
    }

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

    @Test func failClosedStripKeepsEverythingThatIsNotAnHref() {
        let stripped = MailHTMLSanitizer.stripHrefsWithRegex(
            "<p>hi <a/href=\"https://evil.example\" title=\"open\">ntust.edu.tw</a></p>"
        )
        #expect(stripped == "<p>hi <a title=\"open\">ntust.edu.tw</a></p>")
    }

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
