import Foundation
import Testing
@testable import TigerDuck

struct WidgetURLRouterTests {
    @Test func routesLibrary() {
        let url = URL(string: "tigerduck://library")!
        #expect(WidgetURLRouter.route(url) == .library)
    }

    @Test func routesClassTable() {
        let url = URL(string: "tigerduck://classtable")!
        #expect(WidgetURLRouter.route(url) == .classTable)
    }

    @Test func rejectsUnknownHost() {
        let url = URL(string: "tigerduck://nope")!
        #expect(WidgetURLRouter.route(url) == nil)
    }

    @Test func rejectsWrongScheme() {
        let url = URL(string: "https://library")!
        #expect(WidgetURLRouter.route(url) == nil)
    }

    @Test func handlesMalformedGracefully() {
        let url = URL(string: "tigerduck://")!
        #expect(WidgetURLRouter.route(url) == nil)
    }

    // MARK: - Assignment links

    @Test func buildsTheAssignmentLink() {
        #expect(WidgetURLRouter.assignmentURL(id: "901")?.absoluteString == "tigerduck://assignment/901")
    }

    @Test func readsTheAssignmentIdBack() throws {
        for id in ["901", "event-42"] {
            let url = try #require(WidgetURLRouter.assignmentURL(id: id))
            #expect(WidgetURLRouter.assignmentId(from: url) == id)
        }
    }

    @Test func readsNoAssignmentFromOtherLinks() {
        let links = [
            "tigerduck://assignment",
            "tigerduck://assignment/",
            "tigerduck://assignment/901/extra",
            "tigerduck://classtable",
            "https://assignment/901",
            "moodlemobile://https://moodle2.ntust.edu.tw?redirect=/mod/assign/view.php?id%3D5501",
        ]
        for link in links {
            #expect(WidgetURLRouter.assignmentId(from: URL(string: link)!) == nil, "\(link)")
        }
    }
}
