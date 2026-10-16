#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailReadableHTMLTests {
    typealias RGBA = MailReadableHTML.RGBA

    static let dark = MailHTMLTheme.app.background
    static let light = MailHTMLTheme.light.background

    /// Through the sanitizer and the link rewrite first, as the message screen does: only what
    /// survives them reaches the page.
    static func readable(_ raw: String) -> MailReadableHTML {
        MailReadableHTML(MailHTMLSanitizer.rewriteLinks(MailHTMLSanitizer.sanitize(raw, allowRemoteImages: false).html).html)
    }

    // MARK: The page a mail opens on

    /// A colour anywhere counts, a quoted reply's too. A border colour is not a text or
    /// background colour, and `background` never gets past the CSS filter.
    @Test(arguments: [
        ("<p>Hello</p>", false),
        (##"<p style="font-size: 14px; border-left: 1px solid #cccccc">Hello</p>"##, false),
        (##"<p style="background: #000000">Hello</p>"##, false),
        (##"<font color="#000000">Hello</font>"##, true),
        (##"<span style="color: black">Hello</span>"##, true),
        (##"<p style="background-color: #fafafa">Hello</p>"##, true),
        (##"<table bgcolor="#ffffff"><tr><td>Hello</td></tr></table>"##, true),
        (##"<p>Thanks</p><blockquote><p style="color: #1f497d">Quoted</p></blockquote>"##, true),
    ])
    func aMailSaysWhetherItSetsColoursOfItsOwn(html: String, setsColors: Bool) {
        #expect(Self.readable(html).setsColors == setsColors)
    }

    // MARK: Text on its background

    @Test func textOnItsOwnBackgroundIsFixedOnEitherPage() {
        let page = Self.readable(##"<p style="background-color: #ffff00; color: #ffffff">Notice</p>"##)
        for background in [Self.dark, Self.light] {
            #expect(page.html(onPage: background) == ##"<p style="background-color: #ffff00; color: #717171">Notice</p>"##)
        }
    }

    /// The nearest background counts: the second cell's own white, not the table's blue.
    @Test func textOnAnAncestorsBackgroundIsFixedOnEitherPage() {
        let page = Self.readable(
            ##"<table bgcolor="#003366"><tr><td><font color="#000080">Notice</font></td><td bgcolor="#ffffff"><font color="#000080">Notice</font></td></tr></table>"##
        )
        let fixed = ##"<table bgcolor="#003366"><tbody><tr><td><font color="#6998ff">Notice</font></td><td bgcolor="#ffffff"><font color="#000080">Notice</font></td></tr></tbody></table>"##
        #expect(page.html(onPage: Self.dark) == fixed)
        #expect(page.html(onPage: Self.light) == fixed)
    }

    @Test func textOnThePageIsFixedForThePageShown() {
        let page = Self.readable(##"<p><font color="#333333">Dark</font> <font color="#ffffff">Light</font></p>"##)
        #expect(page.html(onPage: Self.dark) == ##"<p><font color="#757575">Dark</font> <font color="#ffffff">Light</font></p>"##)
        #expect(page.html(onPage: Self.light) == ##"<p><font color="#333333">Dark</font> <font color="#767676">Light</font></p>"##)
    }

    @Test func aTranslucentBackgroundLetsThePageShowThrough() {
        let html = ##"<div style="background-color: rgba(0, 0, 0, 0.5)"><p style="color: #808080">Notice</p></div>"##
        let page = Self.readable(html)
        #expect(page.html(onPage: Self.dark) == html)
        #expect(page.html(onPage: Self.light) == ##"<div style="background-color: rgba(0, 0, 0, 0.5)"><p style="color: #171717">Notice</p></div>"##)
    }

    /// A `border-image` with `fill` is the one image that reaches the page behind text. The
    /// sanitizer drops `background` attributes and `background-image`, so text under those
    /// sits on the page and is fixed like any other.
    @Test func textOverABackgroundImageKeepsItsColour() {
        let page = Self.readable(
            ##"<div style="border-image: linear-gradient(#000000, #000000) fill 1"><font color="#333333">Over an image</font></div><table background="paper.png"><tr><td style="background-image: url(paper.png)"><font color="#333333">On the page</font></td></tr></table>"##
        )
        #expect(page.html(onPage: Self.dark)
            == ##"<div style="border-image: linear-gradient(#000000, #000000) fill 1"><font color="#333333">Over an image</font></div><table><tbody><tr><td><font color="#757575">On the page</font></td></tr></tbody></table>"##)
    }

    @Test func textOnABackgroundColourThisCannotReadKeepsItsColour() {
        let page = Self.readable(
            ##"<div style="background-color: hsl(0 0% 0%)"><font color="#333333">a</font></div><table><tr><td bgcolor="#000000ff"><font color="#333333">b</font></td></tr></table><p><font color="#333333">c</font></p>"##
        )
        #expect(page.html(onPage: Self.dark)
            == ##"<div style="background-color: hsl(0 0% 0%)"><font color="#333333">a</font></div><table><tbody><tr><td bgcolor="#000000ff"><font color="#333333">b</font></td></tr></tbody></table><p><font color="#757575">c</font></p>"##)
    }

    /// Translucent text is judged as it shows over its background; invisible text stays invisible.
    @Test func translucentTextIsJudgedAsItShows() {
        let page = Self.readable(##"<p style="color: rgba(0, 0, 0, 0.5)">a</p><p style="color: transparent">b</p>"##)
        #expect(page.html(onPage: Self.dark) == ##"<p style="color: #757575">a</p><p style="color: transparent">b</p>"##)
        #expect(page.html(onPage: Self.light) == ##"<p style="color: #767676">a</p><p style="color: transparent">b</p>"##)
    }

    @Test func onlyTheTextColourChanges() {
        let page = Self.readable(##"<p style="color: #333333 !important; background-color: transparent; border: 1px solid #333333">Notice</p>"##)
        #expect(page.html(onPage: Self.dark)
            == ##"<p style="color: #757575 !important; background-color: transparent; border: 1px solid #333333">Notice</p>"##)
    }

    /// On a mid grey both white and black read; the lightness nearer the sent colour's wins.
    @Test func theNearestLightnessThatReadsWins() {
        let page = Self.readable(##"<p style="background-color: #767676; color: #808080">Notice</p>"##)
        #expect(page.html(onPage: Self.dark) == ##"<p style="background-color: #767676; color: #fefefe">Notice</p>"##)
    }

    @Test func aFixKeepsTheHue() {
        #expect(MailReadableHTML.readable(RGBA(0x1F497D), on: RGBA(0x000000)) == RGBA(0x4B77AE))
        #expect(MailReadableHTML.readable(RGBA(0xFFFF00), on: RGBA(0xFFFFFF)) == RGBA(0x7A7A00))
    }

    /// A fix always reaches the minimum, even rounded to whole bytes, a colour that already
    /// reaches it is never touched, and a grey stays grey.
    @Test func everyFixReachesTheMinimum() {
        for background in [0x000000, 0xFFFFFF, 0x777777, 0x3366CC, 0xFFFF00, 0x123456] as [UInt32] {
            let page = RGBA(background)
            for value in stride(from: 0, through: 0xFFFFFF, by: 0x3F1F) {
                let text = RGBA(UInt32(value))
                let ratio = MailReadableHTML.contrast(text, page)
                if let fixed = MailReadableHTML.readable(text, on: page) {
                    #expect(ratio < MailReadableHTML.minimumContrast, "\(text.css) on \(page.css)")
                    #expect(MailReadableHTML.contrast(fixed, page) >= MailReadableHTML.minimumContrast, "\(text.css) on \(page.css)")
                } else {
                    #expect(ratio >= MailReadableHTML.minimumContrast, "\(text.css) on \(page.css)")
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

    // MARK: Colour forms

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

    /// A colour in a form this reads is written back as `#rrggbb`; one it cannot read stays as sent.
    @Test func aFixedColourIsWrittenAsHex() {
        let page = Self.readable(
            ##"<p style="color: rgb(51 51 51 / 100%)">a</p><p style="color: hsl(0 0% 20%)">b</p><p><font color="DarkSlateGray">c</font><font color="#333333ff">d</font></p>"##
        )
        #expect(page.html(onPage: Self.dark)
            == ##"<p style="color: #757575">a</p><p style="color: hsl(0 0% 20%)">b</p><p><font color="#5a7b7b">c</font><font color="#333333ff">d</font></p>"##)
    }

    // MARK: Nothing else changes

    /// Only colour values change, so no page of any XSS-corpus vector gains a forbidden token or
    /// loses or reorders a link.
    @Test func eitherPageOfTheCorpusKeepsWhatTheSanitizerLeft() {
        for vector in MailHTMLSanitizerTests.corpus {
            let linked = MailHTMLSanitizer.rewriteLinks(MailHTMLSanitizer.sanitize(vector, allowRemoteImages: false).html)
            let page = MailReadableHTML(linked.html)
            for background in [Self.dark, Self.light] {
                let html = page.html(onPage: background)
                for token in MailHTMLSanitizerTests.forbiddenTokens {
                    #expect(!html.lowercased().contains(token), "'\(token)' in: \(vector)")
                }
                #expect(MailHTMLSanitizer.rewriteLinks(html).links == MailHTMLSanitizer.rewriteLinks(linked.html).links, "\(vector)")
            }
        }
    }
}
#endif
