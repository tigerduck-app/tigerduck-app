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
}
