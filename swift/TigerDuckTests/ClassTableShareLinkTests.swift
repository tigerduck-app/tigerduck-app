import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct ClassTableShareLinkTests {
    private nonisolated static let rest = "CLASSTABLE/1KNTO5SJB234O09283J89PYINHMLGU86XQH3K2WVREW0CHIZS78"
    private nonisolated static let code = "HTTPS://SHARE.TIGERDUCK.APP/" + rest
    private static let first = AccountSession.Ticket.after(signOuts: 3)
    private static let second = AccountSession.Ticket.after(signOuts: 4)

    private static func text(_ link: String) throws -> String? {
        ClassTableShareLink.codeText(try #require(URL(string: link), "\(link)"))
    }

    @Test("the code as written, in lower or mixed case, and the share page's tigerduck://share link read as one code")
    func linkForms() throws {
        let expected = try ClassTableShareCode.decode(Self.code)
        for link in [
            Self.code,
            "https://share.tigerduck.app/" + Self.rest.lowercased(),
            "Https://Share.TigerDuck.App/" + Self.rest,
            "tigerduck://share/" + Self.rest,
        ] {
            let text = try #require(try Self.text(link), "\(link)")
            #expect(try ClassTableShareCode.decode(text) == expected, "\(link)")
        }
        #expect(try Self.text(Self.code) == Self.code, "passed on as it came; the decoder upper-cases it")
    }

    @Test("a query or fragment a chat app or the share page adds is left out, so the code still reads")
    func queryAndFragment() throws {
        let expected = try ClassTableShareCode.decode(Self.code)
        for link in [
            Self.code + "?fbclid=IwAR0abc",
            "https://share.tigerduck.app/" + Self.rest + "?openExternalBrowser=1#top",
            "https://share.tigerduck.app/" + Self.rest.lowercased() + "#",
            "tigerduck://share/" + Self.rest + "?utm_source=line#x",
        ] {
            let text = try #require(try Self.text(link), "\(link)")
            #expect(try ClassTableShareCode.decode(text) == expected, "\(link)")
        }
    }

    @Test("everything on the share host goes to the import, which has a message for what it cannot read")
    func shareHostLinks() throws {
        for link in [
            "https://share.tigerduck.app",
            "https://share.tigerduck.app:443/" + Self.rest,
            "https://share.tigerduck.app/FRIEND/1ABC",
        ] {
            #expect(try Self.text(link) == link)
        }
        #expect(try Self.text("https://share.tigerduck.app/?from=mail") == "https://share.tigerduck.app/")
        #expect(try Self.text("tigerduck://share") == "HTTPS://SHARE.TIGERDUCK.APP/")
        #expect(try Self.text("tigerduck://share/friend/1abc?from=mail") == "HTTPS://SHARE.TIGERDUCK.APP/friend/1abc")
        #expect(try Self.text("tigerduck://share//x") == "HTTPS://SHARE.TIGERDUCK.APP//x")
    }

    @Test("the main site, the old tigerduck.app/T/ links, look-alike hosts and other app links are not share links", arguments: [
        "https://tigerduck.app/",
        "https://tigerduck.app/T/1.B11300001.202610131405.1151.OMHDMNBQGQYDAMGUOGDLFDDULROWCYV6RYYFMACMBQAA.E2YUDIQ",
        "https://tigerduck.app/" + rest,
        "https://share.tigerduck.app.example.com/" + rest,
        "https://share.tigerduck.app@example.com/" + rest,
        "https://example.com/" + rest,
        "http://share.tigerduck.app/" + rest,
        "tigerduck://Share/" + rest,
        "tigerduck://classtable",
        "tigerduck://assignment/42",
    ])
    func otherLinks(link: String) throws {
        #expect(try Self.text(link) == nil)
    }

    @Test("a link before sign-in or onboarding is held until both are done, and opens once")
    func heldUntilItMayOpen() {
        let held = HeldShareLink()

        held.arrived("A", signIn: Self.first)

        #expect(held.take(mayOpen: false, signIn: Self.first) == nil)
        #expect(held.link?.text == "A", "still held")
        #expect(held.take(mayOpen: true, signIn: Self.first) == "A")
        #expect(held.take(mayOpen: true, signIn: Self.first) == nil)
        #expect(held.link == nil)
    }

    @Test("a newer link replaces a held one")
    func newerLinkReplaces() {
        let held = HeldShareLink()

        held.arrived("A", signIn: Self.first)
        held.arrived("B", signIn: Self.first)

        #expect(held.take(mayOpen: true, signIn: Self.first) == "B")
        #expect(held.take(mayOpen: true, signIn: Self.first) == nil)
    }

    @Test("a sign-out drops a held link, so it does not open after the next sign-in")
    func signOutDrops() {
        let held = HeldShareLink()
        held.arrived("A", signIn: Self.first)

        #expect(held.take(mayOpen: false, signIn: Self.second) == nil)

        #expect(held.link == nil)
        #expect(held.take(mayOpen: true, signIn: Self.second) == nil)
    }
}
