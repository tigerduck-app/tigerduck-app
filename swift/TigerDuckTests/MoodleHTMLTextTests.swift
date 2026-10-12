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

    @Test("the preview is the text on one line, words kept apart where blocks meet")
    func preview() {
        let html = "<p>Exam&nbsp;on <b>11/4</b>.</p><ul><li>Room TR-412</li><li>Bring&nbsp;&nbsp;ID</li></ul><script>x()</script>"
        #expect(MoodleHTMLText.plainText(fromHTML: html) == "Exam on 11/4. Room TR-412 Bring ID")
    }
}
