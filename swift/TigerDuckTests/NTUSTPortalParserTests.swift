import Foundation
import Testing
@testable import TigerDuck

/// Hand-written pages in the shape of the student portal, `#service` and its groups.
enum PortalPages {
    static let pageURL = URL(string: "https://i.ntust.edu.tw/student")!

    static func page(_ groups: [(id: String, links: [(name: String, href: String)])]) -> String {
        let blocks = groups.map { group in
            let anchors = group.links.map { "<li><a href=\"\($0.href)\" target=\"_blank\">\($0.name)</a></li>" }
            return "<div id=\"\(group.id)\" class=\"service-block\"><ul>\(anchors.joined())</ul></div>"
        }
        return """
        <html><head><title>Student</title></head><body>
        <nav><a href="/logout">Logout</a></nav>
        <div id="service">\(blocks.joined(separator: "\n"))</div>
        </body></html>
        """
    }

    /// One link in each of the six groups, after a shortcut block that repeats one of them.
    static let full = page([
        ("commonly-used-service", [("選課系統", "https://courseselection.ntust.edu.tw/")]),
        ("service-1", [("選課系統", "https://courseselection.ntust.edu.tw/")]),
        ("service-2", [("學籍資料", "/student/record")]),
        ("service-3", [("宿舍申請", "https://dorm.ntust.edu.tw/apply")]),
        ("service-4", [("獎助學金", "https://scholarship.ntust.edu.tw/")]),
        ("service-5", [("交換生選課", "https://oia.ntust.edu.tw/exchange")]),
        ("service-6", [("授權軟體", "https://software.ntust.edu.tw/")]),
    ])
}

struct NTUSTPortalParserTests {
    private static func links(_ html: String) -> [PortalLink]? {
        NTUSTPortalParser.links(in: html, pageURL: PortalPages.pageURL)
    }

    @Test("each of the six groups lands in its category, in page order, without the shortcut block")
    func sixCategories() throws {
        let links = try #require(Self.links(PortalPages.full))

        #expect(links.map(\.category) == PortalCategory.allCases)
        #expect(links.map(\.name) == ["選課系統", "學籍資料", "宿舍申請", "獎助學金", "交換生選課", "授權軟體"])
    }

    @Test("a relative link is resolved against the page and an absolute one is kept")
    func relativeAndAbsolute() throws {
        let links = try #require(Self.links(PortalPages.page([
            ("service-2", [("學籍資料", "/student/record"), ("離校手續", "leave?step=1"), ("操行成績", "https://conduct.ntust.edu.tw/q")]),
        ])))

        #expect(links.map(\.url.absoluteString) == [
            "https://i.ntust.edu.tw/student/record",
            "https://i.ntust.edu.tw/leave?step=1",
            "https://conduct.ntust.edu.tw/q",
        ])
    }

    @Test("an http link on a school host moves to https, and other links that are not https are dropped")
    func httpsOnly() throws {
        let links = try #require(Self.links(PortalPages.page([
            ("service-6", [
                ("Old", "http://old.ntust.edu.tw:80/a%2Fb?x=1"), ("Outside", "http://example.com/"),
                ("Script", "javascript:void(0)"), ("Mail", "mailto:a@ntust.edu.tw"),
                ("   ", "https://blank.ntust.edu.tw/"), ("授權軟體", "https://software.ntust.edu.tw/"),
            ]),
        ])))

        #expect(links.map(\.name) == ["Old", "授權軟體"])
        #expect(links.map(\.url.absoluteString) == ["https://old.ntust.edu.tw/a%2Fb?x=1", "https://software.ntust.edu.tw/"])
    }

    @Test("the research ethics course's old host moves to its new one, keeping escaped separators")
    func movedHost() throws {
        let links = try #require(Self.links(PortalPages.page([
            ("service-5", [("學術研究倫理課程報名", "https://ae.ntust.edu.tw/a%2Fb?x=1%26y=2#top")]),
            ("service-6", [("Other", "https://www.ntust.edu.tw/a%2Fb")]),
        ])))

        #expect(links.map(\.url.absoluteString) == [
            "https://ae.cge.ntust.edu.tw/a%2Fb?x=1%26y=2#top",
            "https://www.ntust.edu.tw/a%2Fb",
        ])
    }

    @Test("the campus software page, in either language, opens the software site's sign-in")
    func campusSoftware() throws {
        let links = try #require(Self.links(PortalPages.page([
            ("service-6", [
                ("校園授權軟體下載", "https://www.cc.ntust.edu.tw/p/412-1050-8352.php?Lang=zh-tw"),
                ("Campus Software Service", "http://www.cc.ntust.edu.tw/p/412-1050-8701.php?Lang=en"),
                ("Other", "https://www.cc.ntust.edu.tw/p/412-1050-1.php?Lang=zh-tw"),
            ]),
        ])))

        #expect(links.map(\.url.absoluteString) == [
            "https://software.ntust.edu.tw/websoftware/login.aspx",
            "https://software.ntust.edu.tw/websoftware/login.aspx",
            "https://www.cc.ntust.edu.tw/p/412-1050-1.php?Lang=zh-tw",
        ])
    }

    @Test("a portal with an empty service block has no links, and a page without one is no portal")
    func emptyOrChanged() {
        #expect(Self.links(PortalPages.page([])) == [])
        #expect(Self.links(#"<div id="services"><div id="service-1"><a href="/x">X</a></div></div>"#) == nil)
        #expect(Self.links("<html><body><form id=\"loginForm\"></form></body></html>") == nil)
        #expect(Self.links("") == nil)
    }

    @Test("an anchor that leads back to the portal page itself is left out")
    func selfLinks() throws {
        let links = try #require(Self.links(PortalPages.page([
            ("service-1", [
                ("Top", "#"), ("Section", "#courses"), ("Empty", ""), ("Same page", "/student#x"),
                ("課程查詢", "https://querycourse.ntust.edu.tw/querycourse/#search"),
            ]),
        ])))

        #expect(links.map(\.name) == ["課程查詢"])
        #expect(links.map(\.url.absoluteString) == ["https://querycourse.ntust.edu.tw/querycourse/#search"])
    }

    @Test("a group the portal adds later is left out")
    func unknownGroup() throws {
        let links = try #require(Self.links(PortalPages.page([
            ("service-7", [("New", "https://new.ntust.edu.tw/")]),
            ("service-1", [("課程查詢", "https://querycourse.ntust.edu.tw/querycourse/")]),
        ])))

        #expect(links.map(\.name) == ["課程查詢"])
    }
}
