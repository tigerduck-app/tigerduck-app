#if os(iOS)
import Foundation
import Security
import Testing
@testable import TigerDuck

@MainActor
struct BrowserRiskAcceptanceTests {
    private let host = "suggestionbox.ntust.edu.tw"

    private var refused: URL { URL(string: "https://Suggestionbox.ntust.edu.tw/form")! }

    @Test("an acceptance holds for the refused host and the leaf it served then, nothing else")
    func onlyTheRefusedLeafOfItsHost() {
        let browser = BrowserRiskAcceptance().accepting(.init(url: refused, leaf: "a"))
        #expect(browser.allows("a", from: host))
        #expect(browser.allows("a", from: "SUGGESTIONBOX.ntust.edu.tw"))
        #expect(!browser.allows("b", from: host))
        #expect(!browser.allows("a", from: "i.ntust.edu.tw"))
        #expect(!browser.allows(nil, from: host))
        #expect(!BrowserRiskAcceptance().allows("a", from: host))
    }

    @Test("a certificate failure offers the address that failed and the leaf its host served at the refusal")
    func theOfferTakesTheLeafAtTheRefusal() {
        let check = BrowserCertificateCheck()
        let failure = BrowserPage.Failure.certificate(host: host)
        #expect(check.offering(failure, at: refused) == failure)

        check.notLetThrough("a", from: "i.ntust.edu.tw")
        check.notLetThrough("b", from: host)
        check.notLetThrough("c", from: "SUGGESTIONBOX.ntust.edu.tw")
        let offered = check.offering(failure, at: refused)
        #expect(offered == .certificate(host: host, refusal: .init(url: refused, leaf: "c")))
        check.notLetThrough("d", from: host)
        #expect(offered == .certificate(host: host, refusal: .init(url: refused, leaf: "c")))

        #expect(check.offering(.unreachable(host: host), at: refused) == .unreachable(host: host))
        #expect(check.offering(failure, at: nil) == failure)
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
