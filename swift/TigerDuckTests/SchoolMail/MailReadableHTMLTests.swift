#if os(iOS)
import Foundation
import Testing
import UIKit
import WebKit
@testable import TigerDuck

struct MailReadableHTMLTests {
    typealias RGBA = MailReadableHTML.RGBA

    static func readable(_ raw: String) -> MailReadableHTML {
        MailReadableHTML(MailHTMLSanitizer.rewriteLinks(MailHTMLSanitizer.sanitize(raw, allowRemoteImages: false).html).html)
    }

    @Test(arguments: [
        ("<p>Hello</p>", false),
        (##"<p style="font-size: 14px; border-left: 1px solid #cccccc">Hello</p>"##, false),
        (##"<p style="background: #000000">Hello</p>"##, false),
        (##"<font color="#000000">Hello</font>"##, true),
        (##"<span style="color: black">Hello</span>"##, true),
        (##"<p style="background-color: #fafafa">Hello</p>"##, true),
        (##"<table bgcolor="#ffffff"><tr><td>Hello</td></tr></table>"##, true),
        (##"<p>Thanks</p><blockquote><p style="color: #1f497d">Quoted</p></blockquote>"##, true),
        (##"<p>Read <a href="https://a.example" style="color: inherit">more</a></p>"##, false),
        (##"<span style="color: currentColor; background-color: transparent">Hello</span>"##, false),
        (##"<p style="background-color: currentColor">Hello</p>"##, true),
        (##"<p style="color: rgba(0, 0, 0, 0); background-color: #fff0">Hello</p>"##, false),
        (##"<table bgcolor="transparent"><tr><td style="color: unset">Hello</td></tr></table>"##, false),
        (##"<p style="color: revert">Hello</p>"##, false),
        (##"<p style="background-color: revert-layer">Hello</p>"##, false),
        (##"<p style="color: initial">Hello</p>"##, true),
        (##"<p style="background-color: initial">Hello</p>"##, false),
        (##"<p style="color: #333333; color: inherit">Hello</p>"##, false),
        (##"<p style="color: inherit; color: #333333">Hello</p>"##, true),
        (##"<font color="#333333" style="color: inherit">Hello</font>"##, false),
        (##"<table><tr><td bgcolor="#ffffff" style="background-color: transparent">Hello</td></tr></table>"##, false),
        (##"<p style="color: hsl(0 0% 20%)">Hello</p>"##, true),
    ])
    func aMailSaysWhetherItSetsColoursOfItsOwn(html: String, setsColors: Bool) {
        #expect(Self.readable(html).setsColors == setsColors)
    }

    @Test func textOnItsOwnBackgroundIsFixedOnEitherPage() {
        let page = Self.readable(##"<p style="background-color: #ffff00; color: #ffffff">Notice</p>"##)
        for theme in [MailHTMLTheme.app, .light] {
            #expect(page.html(on: theme) == ##"<p style="background-color: #ffff00; color: #545454">Notice</p>"##)
        }
    }

    @Test func textOnAnAncestorsBackgroundIsFixedOnEitherPage() {
        let page = Self.readable(
            ##"<table bgcolor="#003366" style="color: #ffffff"><tr><td><font color="#000080">Notice</font></td><td bgcolor="#ffffff" style="color: #000000"><font color="#000080">Notice</font></td></tr></table>"##
        )
        let fixed = ##"<table bgcolor="#003366" style="color: #ffffff"><tbody><tr><td><font color="#a3c2ff">Notice</font></td><td bgcolor="#ffffff" style="color: #000000"><font color="#000080">Notice</font></td></tr></tbody></table>"##
        #expect(page.html(on: .app) == fixed)
        #expect(page.html(on: .light) == fixed)
    }

    @Test func textOnThePageIsFixedForThePageShown() {
        let page = Self.readable(##"<p><font color="#333333">Dark</font> <font color="#ffffff">Light</font></p>"##)
        #expect(page.html(on: .app) == ##"<p><font color="#959595">Dark</font> <font color="#ffffff">Light</font></p>"##)
        #expect(page.html(on: .light) == ##"<p><font color="#333333">Dark</font> <font color="#595959">Light</font></p>"##)
    }

    @Test func aTranslucentBackgroundLetsThePageShowThrough() {
        let page = Self.readable(##"<div style="background-color: rgba(0, 0, 0, 0.5)"><p style="color: #808080">Notice</p></div>"##)
        #expect(page.html(on: .app) == ##"<div style="background-color: rgba(0, 0, 0, 0.5)"><p style="color: #959595">Notice</p></div>"##)
        #expect(page.html(on: .light) == ##"<div style="background-color: rgba(0, 0, 0, 0.5)"><p style="color: #000000">Notice</p></div>"##)
    }

    @Test func translucentLayersStack() {
        let page = Self.readable(
            ##"<div style="background-color: rgba(255, 0, 0, 0.5)"><div style="background-color: rgba(0, 0, 255, 0.5)"><p style="color: #800080">x</p></div></div>"##
        )
        #expect(page.html(on: .app)
            == ##"<div style="background-color: rgba(255, 0, 0, 0.5)"><div style="background-color: rgba(0, 0, 255, 0.5)"><p style="color: #ff91fc">x</p></div></div>"##)
        #expect(page.html(on: .light)
            == ##"<div style="background-color: rgba(255, 0, 0, 0.5)"><div style="background-color: rgba(0, 0, 255, 0.5); color: #ffffff"><p style="color: #ffffff">x</p></div></div>"##)
    }

    @Test func onAMidToneTheBetterOfWhiteAndBlackIsTheFix() {
        let page = Self.readable(##"<p style="background-color: #777777; color: #808080">Notice</p>"##)
        #expect(page.html(on: .app) == ##"<p style="background-color: #777777; color: #000000">Notice</p>"##)
        #expect(MailReadableHTML.readable(RGBA(0x000000), on: RGBA(0x777777)) == nil)
    }

    @Test func textOverABackgroundImageKeepsItsColour() {
        let page = Self.readable(
            ##"<div style="border-image: linear-gradient(#000000, #000000) fill 1"><font color="#333333">Over an image</font></div><table background="paper.png"><tr><td style="background-image: url(paper.png)"><font color="#333333">On the page</font></td></tr></table>"##
        )
        #expect(page.html(on: .app)
            == ##"<div style="border-image: linear-gradient(#000000, #000000) fill 1"><font color="#333333">Over an image</font></div><table><tbody><tr><td><font color="#959595">On the page</font></td></tr></tbody></table>"##)
    }

    @Test func anOpaqueBackgroundCoversOneThisCannotRead() {
        let page = Self.readable(
            ##"<div style="border-image: linear-gradient(#000000, #000000) fill 1"><p style="background-color: #000000"><font color="#333333">Covered</font></p></div>"##
        )
        #expect(page.html(on: .app)
            == ##"<div style="border-image: linear-gradient(#000000, #000000) fill 1"><p style="background-color: #000000"><font color="#959595">Covered</font></p></div>"##)
    }

    @Test func theBorderImageLonghandCountsAsAnImage() {
        let page = Self.readable(##"<div style="border-image-source: linear-gradient(#000000, #000000)"><font color="#333333">a</font></div><p><font color="#333333">b</font></p>"##)
        #expect(page.html(on: .app)
            == ##"<div style="border-image-source: linear-gradient(#000000, #000000)"><font color="#333333">a</font></div><p><font color="#959595">b</font></p>"##)
    }

    @Test func aTableWithColumnBackgroundsCannotBeRead() {
        let page = Self.readable(
            ##"<table><colgroup><col style="background-color: #000000"></colgroup><tr><td><font color="#333333">a</font></td></tr></table><table><col style="background-color: #000000"><tr><td><font color="#333333">b</font></td></tr></table><table><tr><td><font color="#333333">c</font></td></tr></table>"##
        )
        #expect(page.html(on: .app)
            == ##"<table><colgroup><col style="background-color: #000000" /></colgroup><tbody><tr><td><font color="#333333">a</font></td></tr></tbody></table><table><colgroup><col style="background-color: #000000" /></colgroup><tbody><tr><td><font color="#333333">b</font></td></tr></tbody></table><table><tbody><tr><td><font color="#959595">c</font></td></tr></tbody></table>"##)
    }

    /// WebKit paints a table's background over its grid only, so its caption is judged on what the
    /// table sits on, and given back the colour the table was given in its place
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/677).
    @Test func aCaptionSitsOnWhatItsTableSitsOn() {
        let black = Self.readable(##"<table bgcolor="#000000"><caption><font color="#333333">Caption</font></caption><tr><td>Cell</td></tr></table>"##)
        #expect(black.html(on: .light)
            == ##"<table bgcolor="#000000" style="color: #959595"><caption style="color: #000000"><font color="#333333">Caption</font></caption><tbody><tr><td>Cell</td></tr></tbody></table>"##)
        let white = Self.readable(##"<table bgcolor="#ffffff"><caption>Caption</caption><tr><td>Cell</td></tr></table>"##)
        #expect(white.html(on: .app)
            == ##"<table bgcolor="#ffffff" style="color: #595959"><caption style="color: #ffffff">Caption</caption><tbody><tr><td>Cell</td></tr></tbody></table>"##)
        #expect(white.html(on: .light) == ##"<table bgcolor="#ffffff"><caption>Caption</caption><tbody><tr><td>Cell</td></tr></tbody></table>"##)
    }

    @Test(arguments: [##"<table bgcolor="#000000" style="display: block">"##, ##"<table bgcolor="#000000"><caption style="display: block">"##])
    func aCaptionOutOfTableLayoutSitsOnTheTable(opening: String) {
        let html = opening.hasSuffix("<caption style=\"display: block\">")
            ? opening + ##"<font color="#333333">Caption</font></caption><tr><td>Cell</td></tr></table>"##
            : opening + ##"<caption><font color="#333333">Caption</font></caption><tr><td>Cell</td></tr></table>"##
        let out = Self.readable(html).html(on: .light)
        #expect(!out.contains(##"<font color="#333333">"##))
        #expect(!out.contains(##"style="color: #000000""##))
    }

    @Test func textOnABackgroundColourThisCannotReadKeepsItsColour() {
        let page = Self.readable(
            ##"<div style="background-color: hsl(0 0% 0%)"><font color="#333333">a</font></div><table><tr><td bgcolor="#000000ff"><font color="#333333">b</font></td></tr></table><p><font color="#333333">c</font></p>"##
        )
        #expect(page.html(on: .app)
            == ##"<div style="background-color: hsl(0 0% 0%)"><font color="#333333">a</font></div><table><tbody><tr><td bgcolor="#000000ff"><font color="#333333">b</font></td></tr></tbody></table><p><font color="#959595">c</font></p>"##)
    }

    @Test func anInlineBackgroundOutranksBgcolor() {
        let page = Self.readable(##"<table><tr><td bgcolor="#ffffff" style="background-color: #000000"><font color="#333333">x</font></td></tr></table>"##)
        #expect(page.html(on: .app)
            == ##"<table><tbody><tr><td bgcolor="#ffffff" style="background-color: #000000"><font color="#959595">x</font></td></tr></tbody></table>"##)
    }

    @Test func anImportantBackgroundOutranksALaterOne() {
        let page = Self.readable(##"<p style="background-color: #000000 !important; background-color: #ffffff; color: #333333">x</p>"##)
        #expect(page.html(on: .app) == ##"<p style="background-color: #000000 !important; background-color: #ffffff; color: #959595">x</p>"##)
    }

    @Test func aColorDeclarationOutranksFontColor() {
        let page = Self.readable(##"<p><font color="#ffffff" style="color: #333333">a</font><font color="#333333" style="color: hsl(0 0% 20%)">b</font></p>"##)
        #expect(page.html(on: .app)
            == ##"<p><font color="#ffffff" style="color: #959595">a</font><font color="#333333" style="color: hsl(0 0% 20%)">b</font></p>"##)
    }

    @Test func translucentTextIsJudgedAsItShows() {
        let page = Self.readable(##"<p style="color: rgba(0, 0, 0, 0.5)">a</p><p style="color: transparent">b</p>"##)
        #expect(page.html(on: .app) == ##"<p style="color: #959595">a</p><p style="color: transparent">b</p>"##)
        #expect(page.html(on: .light) == ##"<p style="color: #595959">a</p><p style="color: transparent">b</p>"##)
    }

    @Test func onlyTheTextColourChanges() {
        let page = Self.readable(##"<p style="color: #333333 !important; background-color: transparent; border: 1px solid #333333">Notice</p>"##)
        #expect(page.html(on: .app)
            == ##"<p style="color: #959595 !important; background-color: transparent; border: 1px solid #333333">Notice</p>"##)
    }

    @Test func aFixKeepsTheHue() {
        #expect(MailReadableHTML.readable(RGBA(0x1F497D), on: RGBA(0x000000)) == RGBA(0x6B98D2))
        #expect(MailReadableHTML.readable(RGBA(0xFFFF00), on: RGBA(0xFFFFFF)) == RGBA(0x5C5C00))
    }

    @Test func everyFixReachesTheTarget() {
        for background in [0x000000, 0xFFFFFF, 0x777777, 0x3366CC, 0xFFFF00, 0x123456] as [UInt32] {
            let page = RGBA(background)
            let best = max(MailReadableHTML.contrast(RGBA(0xFFFFFF), page), MailReadableHTML.contrast(RGBA(0x000000), page))
            let target = min(MailReadableHTML.minimumContrast, best)
            for value in stride(from: 0, through: 0xFFFFFF, by: 0x3F1F) {
                let text = RGBA(UInt32(value))
                let ratio = MailReadableHTML.contrast(text, page)
                if let fixed = MailReadableHTML.readable(text, on: page) {
                    #expect(ratio < target, "\(text.css) on \(page.css)")
                    #expect(MailReadableHTML.contrast(fixed, page) >= target, "\(text.css) on \(page.css)")
                } else {
                    #expect(ratio >= target, "\(text.css) on \(page.css)")
                }
            }
        }
        for level in 0...255 {
            let grey = RGBA(UInt32(level) * 0x010101)
            for page in [RGBA(0x000000), RGBA(0xFFFFFF)] {
                guard let fixed = MailReadableHTML.readable(grey, on: page) else { continue }
                #expect(fixed.red == fixed.green && fixed.green == fixed.blue, "\(grey.css) became \(fixed.css)")
            }
        }
    }

    @Test func aHighlightWithNoColourOfItsOwnIsGivenOne() {
        let html = ##"<p>Read <span style="background-color: #ffff00">this</span> first</p>"##
        let page = Self.readable(html)
        #expect(page.html(on: .app) == ##"<p>Read <span style="background-color: #ffff00; color: #545454">this</span> first</p>"##)
        #expect(page.html(on: .light) == html)
    }

    @Test func aBackgroundGetsBackTheColourTheSenderMeant() {
        let page = Self.readable(##"<div style="color: #000000">Hi <span style="background-color: #ffff00">there</span></div>"##)
        #expect(page.html(on: .app) == ##"<div style="color: #959595">Hi <span style="background-color: #ffff00; color: #000000">there</span></div>"##)
    }

    @Test func aLinkOnTheSendersBackgroundIsFixed() {
        let page = Self.readable(
            ##"<table bgcolor="#000000"><tr><td>Text <a href="https://a.example">link</a></td></tr></table><p><a href="https://b.example">page link</a></p>"##
        )
        #expect(page.html(on: .light)
            == ##"<table bgcolor="#000000" style="color: #959595"><tbody><tr><td>Text <a href="https://link.invalid/0" style="color: #6092ff">link</a></td></tr></tbody></table><p><a href="https://link.invalid/1">page link</a></p>"##)
        #expect(page.html(on: .app)
            == ##"<table bgcolor="#000000"><tbody><tr><td>Text <a href="https://link.invalid/0">link</a></td></tr></tbody></table><p><a href="https://link.invalid/1">page link</a></p>"##)
    }

    @Test func aHighlightInsideALinkStartsFromTheLinkColour() {
        let page = Self.readable(##"<p><a href="https://a.example"><span style="background-color: #ffff00">Marked</span> link</a></p>"##)
        #expect(page.html(on: .app)
            == ##"<p><a href="https://link.invalid/0"><span style="background-color: #ffff00; color: #4e48a1">Marked</span> link</a></p>"##)
    }

    @Test func aLinkInsideColouredTextKeepsTheLinkColour() {
        let page = Self.readable(##"<div style="background-color: #000000; color: #ffffff">Text <a href="https://a.example">link</a></div>"##)
        #expect(page.html(on: .light)
            == ##"<div style="background-color: #000000; color: #ffffff">Text <a href="https://link.invalid/0" style="color: #6092ff">link</a></div>"##)
    }

    @Test(arguments: [
        "#333", "#333F", "#333333", "#333333ff", "rgb(51, 51, 51)", "rgba(51, 51, 51, 1)", "RGB(20% 20% 20%)",
        "rgb(51 51 51 / 100%)", "rgba(51 51 51 / 1)",
    ])
    func everyCSSFormOfAColourIsRead(value: String) {
        #expect(MailReadableHTML.parse(value[...], legacy: false) == RGBA(0x333333))
    }

    @Test func namedAndTranslucentColoursAreRead() {
        #expect(MailReadableHTML.parse("DarkSlateGray", legacy: false) == RGBA(0x2F4F4F))
        #expect(MailReadableHTML.parse("rebeccapurple", legacy: true) == RGBA(0x663399))
        #expect(MailReadableHTML.parse("transparent", legacy: false)?.alpha == 0)
        #expect(MailReadableHTML.parse("rgba(255, 0, 0, 50%)", legacy: false) == RGBA(red: 1, green: 0, blue: 0, alpha: 0.5))
        #expect(MailReadableHTML.parse("#ff000080", legacy: false) == RGBA(red: 1, green: 0, blue: 0, alpha: 128.0 / 255))
    }

    @Test(arguments: [
        "hsl(0, 0%, 20%)", "currentcolor", "inherit", "var(--ink)", "#33", "#33333", "#ggg", "rgb(51, 51)",
        "rgb(51 51 51 51)", "rgb(20%, 51, 51)", "rgb(nan, 0, 0)", "rgb(0x33, 0, 0)", "rgb (51, 51, 51)",
    ])
    func formsThisCannotReadAreNotGuessed(value: String) {
        #expect(MailReadableHTML.parse(value[...], legacy: false) == nil)
    }

    /// `bgcolor` and `<font color>` follow HTML's legacy colour rules, which read `#333333ff` or
    /// `rgb()` as some other colour, so only the forms both rules agree on are read there.
    @Test func bgcolorAndFontColorTakeOnlyTheFormsHTMLReadsAsCSSDoes() {
        #expect(MailReadableHTML.parse("#333", legacy: true) == RGBA(0x333333))
        #expect(MailReadableHTML.parse("#333333", legacy: true) == RGBA(0x333333))
        #expect(MailReadableHTML.parse("DarkSlateGray", legacy: true) == RGBA(0x2F4F4F))
        for value in ["#333f", "#333333ff", "rgb(51, 51, 51)", "333333"] {
            #expect(MailReadableHTML.parse(value[...], legacy: true) == nil, "\(value)")
        }
    }

    @Test func aFixedColourIsWrittenAsHex() {
        let page = Self.readable(
            ##"<p style="color: rgb(51 51 51 / 100%)">a</p><p style="color: hsl(0 0% 20%)">b</p><p><font color="DarkSlateGray">c</font><font color="#333333ff">d</font></p>"##
        )
        #expect(page.html(on: .app)
            == ##"<p style="color: #959595">a</p><p style="color: hsl(0 0% 20%)">b</p><p><font color="#7a9c9c">c</font><font color="#333333ff">d</font></p>"##)
    }

    @Test func coloursDeeperThanTheCapStayAsSent() {
        for (wrappers, fixed) in [(AppConstants.maximumHTMLDepth - 1, true), (AppConstants.maximumHTMLDepth, false)] {
            let html = String(repeating: "<div>", count: wrappers) + ##"<font color="#333333">x</font>"## + String(repeating: "</div>", count: wrappers)
            #expect(MailReadableHTML(html).html(on: .app).contains(##"color="#959595""##) == fixed, "\(wrappers) wrappers")
        }
    }

    @Test func pastTheSearchCapAFixIsWhiteOrBlack() {
        let colours = (0...MailReadableHTML.maximumSearches).map { String(format: "#%02x%02x%02x", $0 % 16, $0 / 16 % 16, $0 / 256) }
        let page = MailReadableHTML(colours.map { #"<font color="\#($0)">x</font>"# }.joined()).html(on: .app)
        #expect(page.hasPrefix(##"<font color="#959595">x</font>"##))
        #expect(page.hasSuffix(##"<font color="#ffffff">x</font>"##))
        #expect(page.components(separatedBy: "#ffffff").count == 2)
    }

    @Test func aCancelledReadLeavesTheColoursAsSent() async {
        let html = ##"<p style="color: #333333">x</p>"##
        let (readWhileCancelled, sawColours) = await Task { () -> (String, Bool) in
            withUnsafeCurrentTask { $0?.cancel() }
            let readable = MailReadableHTML(html)
            return (readable.html(on: .app), readable.setsColors)
        }.value
        let writtenWhileCancelled = await Task { () -> String in
            let readable = MailReadableHTML(html)
            withUnsafeCurrentTask { $0?.cancel() }
            return readable.html(on: .app)
        }.value
        #expect(readWhileCancelled == html)
        #expect(!sawColours)
        #expect(writtenWhileCancelled == html)
        #expect(MailReadableHTML(html).html(on: .app) == ##"<p style="color: #959595">x</p>"##)
    }

    @Test func pagesComeOutTheSameInAnyOrder() {
        let html = MailHTMLSanitizer.rewriteLinks(MailHTMLSanitizer.sanitize(
            ##"<table bgcolor="#003366"><tr><td><font color="#000080">Notice</font></td><td bgcolor="#ffffff"><font color="#000080">Notice</font></td></tr></table>"##,
            allowRemoteImages: false
        ).html).html
        let shared = MailReadableHTML(html)
        let pages = [shared.html(on: .light), shared.html(on: .app), shared.html(on: .light), shared.html(on: .app)]
        #expect(pages[0] == MailReadableHTML(html).html(on: .light))
        #expect(pages[1] == MailReadableHTML(html).html(on: .app))
        #expect(pages[2] == pages[0])
        #expect(pages[3] == pages[1])
        #expect(pages[0] != pages[1])
    }

    @Test func anElementLeftAloneKeepsItsBytes() {
        #expect(MailReadableHTML("<p><font color=#333333>a</font> <font color='#ffffff'>b</font></p>").html(on: .app)
            == ##"<p><font color="#959595">a</font> <font color='#ffffff'>b</font></p>"##)
    }

    @Test func linkAndImageTargetsAreListedInOrder() {
        let html = ##"<a href="https://link.invalid/0">x</a><img src="tdcid:a" /><img data-remote-src="https://x.example/p.png" /><p title=" src=&quot;y&quot;">t</p>"##
        #expect(MailReadableHTML.targets(in: html) == [#" href="https://link.invalid/0""#, #" src="tdcid:a""#])
    }

    @Test func eitherPageOfTheCorpusChangesOnlyColours() throws {
        let carriers = ##"<p style="font-family: &quot;A&amp;B&quot;, serif; color: #808080 !important">x</p><div style="font-family: 'Noto Sans'; background-color: #ffffff">y</div><div style="background-color: #000000 !important"><a href="https://a.example">z</a></div><font color="#808080">w</font>"##
        let writes: [(MailHTMLTheme, [String])] = [
            (.app, ["color: #959595 !important", ##"background-color: #ffffff; color: #595959">y"##, ##"<font color="#959595">w"##]),
            (.light, ["color: #595959 !important", ##"background-color: #000000 !important; color: #959595">"##,
                      ##" style="color: #6092ff">z"##, ##"<font color="#595959">w"##]),
        ]
        let given = try NSRegularExpression(pattern: #"; color: #[0-9a-f]{6}(?=")| style="color: #[0-9a-f]{6}""#)
        let hex = try NSRegularExpression(pattern: "#[0-9a-f]{6}")
        let colourless = { (html: String) -> String in
            let ungiven = given.stringByReplacingMatches(in: html, range: NSRange(html.startIndex..., in: html), withTemplate: "")
            return hex.stringByReplacingMatches(in: ungiven, range: NSRange(ungiven.startIndex..., in: ungiven), withTemplate: "#")
        }
        for vector in MailHTMLSanitizerTests.corpus {
            let linked = MailHTMLSanitizer.rewriteLinks(MailHTMLSanitizer.sanitize(vector + carriers, allowRemoteImages: false).html)
            let page = MailReadableHTML(linked.html)
            for (theme, expected) in writes {
                let html = page.html(on: theme)
                for write in expected {
                    #expect(html.contains(write), "'\(write)' missing on the \(theme.isDark ? "dark" : "light") page: \(vector)")
                }
                for token in MailHTMLSanitizerTests.forbiddenTokens {
                    #expect(!html.lowercased().contains(token), "'\(token)' in: \(vector)")
                }
                #expect(MailHTMLSanitizer.rewriteLinks(html).links == MailHTMLSanitizer.rewriteLinks(linked.html).links, "\(vector)")
                #expect(colourless(html) == colourless(linked.html), "\(vector)")
            }
        }
    }

    @MainActor
    @Test(arguments: [MailHTMLTheme.app, MailHTMLTheme.light])
    func theLinkColourIsWebKitsOwn(theme: MailHTMLTheme) async {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 375, height: 200))
        let webView = WKWebView(frame: window.bounds)
        window.addSubview(webView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let body = #"<a href="https://link.invalid/0">link</a>"#
        webView.loadHTMLString(MailWebViewFactory.document(for: body, allowRemoteImages: false, theme: theme), baseURL: nil)
        let probe = #"document.readyState == "complete" ? getComputedStyle(document.querySelector("a")).color : """#
        var drawn = ""
        for _ in 0..<200 where drawn.isEmpty {
            drawn = (try? await webView.evaluateJavaScript(probe) as? String) ?? ""
            if drawn.isEmpty { try? await Task.sleep(for: .milliseconds(50)) }
        }
        let link = theme.link
        #expect(drawn == "rgb(\(link >> 16 & 0xFF), \(link >> 8 & 0xFF), \(link & 0xFF))")
    }
}
#endif
