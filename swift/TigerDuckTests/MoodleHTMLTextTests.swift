import Foundation
import Testing
@testable import TigerDuck

/// Moodle message HTML, shaped as NTUST's announcements use it (`p`, `div`, `span`, `br`, lists,
/// links and `h3`), turned into the Markdown and the preview the app shows.
struct MoodleHTMLTextTests {
    @Test("paragraphs and divs become blocks, and a break stays a line break")
    func blocks() {
        let html = #"<p dir="ltr" style="text-align: left;">Dear all,</p><div><span>Line one</span><br>line two</div>"#
        #expect(MoodleHTMLText.markdown(fromHTML: html) == "Dear all,\n\nLine one  \nline two")
    }

    @Test("headings, emphasis and nested lists keep their structure")
    func structure() {
        let html = """
        <h3>Midterm</h3>
        <p>Bring <strong>your ID</strong> and <em>a pencil</em>.</p>
        <ol><li>Chapters 1 to 6<ul><li>Lab 1</li><li>Lab 2</li></ul></li><li>Review notes</li></ol>
        """
        #expect(MoodleHTMLText.markdown(fromHTML: html) == """
        ### Midterm

        Bring **your ID** and *a pencil*.

        1. Chapters 1 to 6
           - Lab 1
           - Lab 2
        2. Review notes
        """)
    }

    @Test("a list numbers from its start, kept within what CommonMark reads and what an Int holds")
    func listStart() {
        #expect(MoodleHTMLText.markdown(fromHTML: #"<ol start="3"><li>c</li><li>d</li></ol>"#) == "3. c\n4. d")
        #expect(MoodleHTMLText.markdown(fromHTML: #"<ol start="-2"><li>a</li></ol>"#) == "0. a")
        #expect(MoodleHTMLText.markdown(fromHTML: #"<ol start="9223372036854775807"><li>a</li><li>b</li></ol>"#)
            == "999999000. a\n999999001. b")
    }

    @Test("links resolve against the site, and only web and mail links stay links")
    func links() {
        let html = """
        <p><a href="/mod/forum/view.php?id=9">the forum</a>, <a href="https://example.com/a b">notes</a>, \
        <a href="javascript:alert(1)">this</a> and <a href="mailto:ta@example.com">mail</a></p>
        """
        #expect(MoodleHTMLText.markdown(fromHTML: html, baseURL: URL(string: "https://moodle2.ntust.edu.tw")!)
            == "[the forum](<https://moodle2.ntust.edu.tw/mod/forum/view.php?id=9>), "
            + "[notes](<https://example.com/a%20b>), this and [mail](<mailto:ta@example.com>)")
    }

    @Test("text that looks like Markdown stays text")
    func escaping() {
        let html = "<p>- not a list</p><p>1. not numbered</p><p>#hashtag *stars* [brackets] a_b</p>"
        #expect(MoodleHTMLText.markdown(fromHTML: html)
            == "\\- not a list\n\n1\\. not numbered\n\n\\#hashtag \\*stars\\* \\[brackets\\] a\\_b")
    }

    @Test("an image becomes a link named by its text or its file")
    func images() {
        let html = #"<p><img src="https://moodle2.ntust.edu.tw/webservice/pluginfile.php/1/mod_forum/post/7/map%20v2.png" alt=""></p>"#
        #expect(MoodleHTMLText.markdown(fromHTML: html)
            == "[map v2.png](<https://moodle2.ntust.edu.tw/webservice/pluginfile.php/1/mod_forum/post/7/map%20v2.png>)")
    }

    @Test("an embedded image points at its file even when nothing else in the text changes")
    func pluginFileImage() {
        let url = "https://moodle2.ntust.edu.tw/webservice/pluginfile.php/1/mod_assign/intro/chart.png"
        let file = MoodleFile(name: "chart.png", size: 1, url: url, mimeType: "image/png", modified: nil)
        let html = MoodleHTMLText.resolvingPluginFiles(
            in: #"<p><img src="@@PLUGINFILE@@/chart.png" alt="chart"></p>"#, files: [file]
        )
        #expect(!html.contains("@@PLUGINFILE@@"))
        #expect(html.contains(#"src="\#(url)""#))
    }

    @Test("the preview is the text on one line, words kept apart where blocks meet")
    func preview() {
        let html = "<p>Exam&nbsp;on <b>11/4</b>.</p><ul><li>Room TR-412</li><li>Bring&nbsp;&nbsp;ID</li></ul><script>x()</script>"
        #expect(MoodleHTMLText.plainText(fromHTML: html) == "Exam on 11/4. Room TR-412 Bring ID")
    }

    /// A writer that recursed once per level would overflow the stack thousands of levels down
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/705).
    @Test("HTML nested far deeper than the cap keeps its text",
          arguments: [("<div>", "</div>"), ("<span>", "</span>"), ("<blockquote>", "</blockquote>"), ("<ul><li>", "</li></ul>")])
    func deepNesting(open: String, close: String) {
        let html = String(repeating: open, count: 10_000) + "deep" + String(repeating: close, count: 10_000)
        #expect(MoodleHTMLText.markdown(fromHTML: html).hasSuffix("deep"))
        #expect(MoodleHTMLText.plainText(fromHTML: html) == "deep")
    }

    /// Quotes, code, links and nested inline runs come out as they did before the depth cap.
    @Test("ordinary nesting is written as before")
    func ordinaryNesting() {
        let html = "<h4>Week 3</h4><blockquote><p>Quoted <em>note</em></p><ul><li>one</li>"
            + "<li>two <a href=\"/mod/forum/view.php?id=7\">forum</a></li></ul></blockquote>"
            + "<pre>  let x = 1\n  print(x)</pre><p>Run <code>make test</code> before <strong>Friday</strong>.</p>"
            + "<div><div><p>Nested <span><b>bold <i>both</i></b></span> text</p></div></div>"
        #expect(MoodleHTMLText.markdown(fromHTML: html) == """
        #### Week 3

        > Quoted *note*
        >
        > - one
        > - two [forum](<https://moodle2.ntust.edu.tw/mod/forum/view.php?id=7>)

        ```
          let x = 1
          print(x)
        ```

        Run `make test` before **Friday**.

        Nested **bold *both*** text
        """)
        #expect(MoodleHTMLText.plainText(fromHTML: html)
            == "Week 3 Quoted note one two forum let x = 1 print(x) Run make test before Friday. Nested bold both text")
    }

    /// The bold run sits at the deepest depth written, then one deeper, where it is plain text.
    @Test("an element deeper than the cap is written as its plain text")
    func pastTheCap() {
        for (wrappers, written) in [(AppConstants.maximumHTMLDepth - 1, "**x** y"), (AppConstants.maximumHTMLDepth, "x y")] {
            let html = String(repeating: "<div>", count: wrappers) + "<b>x</b> y" + String(repeating: "</div>", count: wrappers)
            #expect(MoodleHTMLText.markdown(fromHTML: html) == written, "\(wrappers) wrappers")
        }
    }
}
