#if os(iOS)
import Foundation
import Security
import Testing
@testable import TigerDuck

@MainActor
struct BrowserRiskAcceptanceTests {
    private let host = "suggestionbox.ntust.edu.tw"

    @Test("an acceptance holds for the host and the leaf it served when refused, nothing else")
    func onlyTheRefusedLeafOfItsHost() {
        var browser = BrowserRiskAcceptance(launch: .init())
        #expect(!browser.canAccept(host: host))
        browser.accept(host: host)
        #expect(!browser.allows("a", from: host))

        browser.checked("a", from: host, letThrough: false)
        #expect(browser.canAccept(host: host))
        #expect(!browser.allows("a", from: host))
        browser.accept(host: "Suggestionbox.ntust.edu.tw")

        #expect(browser.allows("a", from: host))
        #expect(!browser.allows("b", from: host))
        #expect(!browser.allows("a", from: "i.ntust.edu.tw"))
        #expect(!browser.allows(nil, from: host))
    }

    @Test("a new browser refuses a page carried over an earlier browser's accepted connection")
    func aNewBrowserRefusesAReusedConnection() {
        let launch = BrowserRiskAcceptance.Launch()
        var first = BrowserRiskAcceptance(launch: launch)
        first.checked("a", from: host, letThrough: false)
        first.accept(host: host)
        #expect(!first.refusesUnchecked("a", from: host))

        var second = BrowserRiskAcceptance(launch: launch)
        #expect(!second.allows("a", from: host))
        #expect(second.refusesUnchecked("a", from: host))
        #expect(!second.refusesUnchecked("b", from: host))
        #expect(!BrowserRiskAcceptance(launch: .init()).refusesUnchecked("a", from: host))

        second.checked("a", from: host, letThrough: false)
        second.accept(host: host)
        #expect(!second.refusesUnchecked("a", from: host))
    }

    @Test("a leaf the browser's own check let through, as after new pins arrive, is not refused")
    func aLeafCheckedHereIsNotRefused() {
        let launch = BrowserRiskAcceptance.Launch()
        var first = BrowserRiskAcceptance(launch: launch)
        first.checked("a", from: host, letThrough: false)
        first.accept(host: host)

        var second = BrowserRiskAcceptance(launch: launch)
        second.checked("a", from: host, letThrough: true)
        #expect(!second.refusesUnchecked("a", from: host))
    }

    @Test("the leaf is the SHA-256 of the served leaf certificate")
    func theLeafHashesTheFirstCertificate() throws {
        let certificates = try TLSPinningDelegateTests.cyberChain.map {
            try #require(SecCertificateCreateWithData(nil, Data($0) as CFData))
        }
        var trust: SecTrust?
        SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, nil), &trust)

        let leaf = try #require(BrowserRiskAcceptance.leaf(of: trust))
        let shown = BrowserCertificate(id: 0, certificates[0]).sha256
        #expect(leaf == shown.replacingOccurrences(of: ":", with: "").lowercased())
        #expect(BrowserRiskAcceptance.leaf(of: nil) == nil)
    }
}
#endif
