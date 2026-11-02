import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct DemoPortalTests {
    @Test("demo.json gives every category a link, with a name in each language and a URL of its own")
    func bundledLinks() throws {
        let zh = DemoPortal.links(in: .zh)
        let en = DemoPortal.links(in: .en)

        #expect(Set(zh.map(\.category)) == Set(PortalCategory.allCases))
        #expect(zh.map(\.url) == en.map(\.url))
        #expect(Set(zh.map(\.url)).count == zh.count)
        #expect(zh.allSatisfy { $0.url.scheme == "https" && !BrowserRouting.isMoodleReturnPage($0.url) })
        #expect(zh.first?.name == "選課系統")
        #expect(en.first?.name == "Course Selection")
    }

    @Test("a demo link's page names its category and the link, escaped, and loads nothing")
    func samplePage() throws {
        let link = PortalLink(category: .resources, name: "Tools & <Docs>", url: URL(string: "https://www.lib.ntust.edu.tw/")!)

        let page = DemoPortal.page(link)

        #expect(page.contains("<h1>Tools &amp; &lt;Docs&gt;</h1>"))
        #expect(page.contains("<title>Tools &amp; &lt;Docs&gt;</title>"))
        #expect(page.contains("<p>\(String(localized: PortalCategory.resources.titleKey))</p>"))
        #expect(!page.contains("src="))
        #expect(!page.contains("href="))
    }

    @Test("only a demo link has a page")
    func pageForURL() throws {
        let link = try #require(DemoPortal.links(in: .en).first)

        #expect(DemoPortal.page(for: link.url, language: .en)?.contains("<h1>\(link.name)</h1>") == true)
        #expect(DemoPortal.page(for: URL(string: "https://moodle2.ntust.edu.tw/my/")!, language: .en) == nil)
    }

    @Test("the demo browser makes a link's page and lets only about:blank load, never a web address")
    func browserDecisions() {
        let link = URL(string: "https://courseselection.ntust.edu.tw/")!
        let blank = URL(string: "about:blank")!
        let pages = BrowserDemoPages(page: { $0 == link ? "<h1>Sample</h1>" : nil })

        #expect(BrowserRouting.decision(for: blank) == .load)
        #expect(pages.decide(link) == .show("<h1>Sample</h1>"))
        #expect(pages.decide(blank) == .allow)
        #expect(pages.decide(link) == .show("<h1>Sample</h1>"))
        #expect(pages.decide(URL(string: "http://courseselection.ntust.edu.tw/")!) == .refuse)
        #expect(pages.decide(URL(string: "https://www.ntust.edu.tw/")!) == .refuse)
    }
}
