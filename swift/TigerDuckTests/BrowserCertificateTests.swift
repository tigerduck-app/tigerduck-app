#if os(iOS)
import Foundation
import Security
import Testing
@testable import TigerDuck

struct BrowserCertificateTests {
    @Test func aServedLeafShowsWhoItIsForAndWhoIssuedIt() throws {
        let der = TLSPinningDelegateTests.cyberChain[0]
        let certificate = try #require(SecCertificateCreateWithData(nil, Data(der) as CFData))

        let shown = BrowserCertificate(id: 0, certificate)

        #expect(shown.subject == .init(
            commonName: "cardsystem.ntust.edu.tw",
            organization: "National Taiwan University of Science and Technology"
        ))
        #expect(shown.issuer == .init(commonName: "TWCA SSL Certification Authority", organization: "TAIWAN-CA"))
        let validity = try #require(shown.notBefore).distance(to: try #require(shown.notAfter))
        #expect(validity > 0)
        #expect(shown.sha256.split(separator: ":").count == 32)
        #expect(shown.title == "cardsystem.ntust.edu.tw")
    }

    @Test func aRootIsIssuedByItself() throws {
        let names = try #require(BrowserCertificate.names(in: TLSPinningDelegateTests.twcaGlobalRoot))
        #expect(names.subject == names.issuer)
        #expect(names.subject.commonName == "TWCA Global Root CA")
    }

    @Test func bytesThatAreNoCertificateGiveNoNames() {
        #expect(BrowserCertificate.names(in: []) == nil)
        #expect(BrowserCertificate.names(in: [0x30, 0x82, 0xFF]) == nil)
        #expect(BrowserCertificate.names(in: [0x30, 0x03, 0x02, 0x01, 0x00]) == nil)
    }
}

struct BrowserChromeCollapseTests {
    @Test func scrollingDownHidesTheChromeAndUpBringsItBack() {
        var chrome = BrowserChromeCollapse()
        chrome.scrolled(to: 100)
        #expect(chrome.isCollapsed)
        chrome.scrolled(to: 300)
        #expect(chrome.isCollapsed)
        chrome.scrolled(to: 290)
        #expect(!chrome.isCollapsed)
    }

    @Test func jitterAndTheTopOfThePageChangeNothing() {
        var chrome = BrowserChromeCollapse()
        chrome.scrolled(to: 30)
        #expect(!chrome.isCollapsed)
        chrome.scrolled(to: 200)
        chrome.scrolled(to: 202)
        #expect(chrome.isCollapsed)
        chrome.scrolled(to: 199)
        #expect(chrome.isCollapsed)
    }

    @Test func tappingTheCapsuleBringsTheChromeBack() {
        var chrome = BrowserChromeCollapse()
        chrome.scrolled(to: 200)
        chrome.expand()
        #expect(!chrome.isCollapsed)
    }
}
#endif
