#if os(iOS)
import Foundation
import Security
import Testing
import WebKit
@testable import TigerDuck

@MainActor
struct BrowserPinnedHostsTests {
    typealias F = TLSPinFixtures

    private static let suggestionbox = "suggestionbox.ntust.edu.tw"
    private static let letsEncrypt = TLSPinningDelegateTests.letsEncryptChain
    private static let date = TLSPinningDelegateTests.novemberDate

    private func trust(_ chain: [[UInt8]], host: String) throws -> SecTrust {
        try #require(F.trust(chain, host: host, at: Self.date))
    }

    private func evaluate(
        _ check: BrowserCertificateCheck, host: String, chain: [[UInt8]] = letsEncrypt
    ) async throws -> URLSession.AuthChallengeDisposition {
        let challenge = URLAuthenticationChallenge(
            protectionSpace: ServerTrustSpace(host: host, trust: try trust(chain, host: host)), proposedCredential: nil,
            previousFailureCount: 0, failureResponse: nil, error: nil, sender: NoChallengeSender()
        )
        return await withCheckedContinuation { done in
            check.evaluate(challenge) { disposition, _ in done.resume(returning: disposition) }
        }
    }

    @Test("suggestionbox's Let's Encrypt chain is left to system trust, which takes it, with no pin check or prompt")
    func aBrowserOnlyHostIsLeftToSystemTrust() async throws {
        let check = BrowserCertificateCheck()
        #expect(try await evaluate(check, host: Self.suggestionbox) == .performDefaultHandling)
        #expect(check.refusedHosts.isEmpty)
        #expect(SecTrustEvaluateWithError(try trust(Self.letsEncrypt, host: Self.suggestionbox), nil))
    }

    @Test("the browser checks pins only for the hosts the app signs in to and those it gives the stored password")
    func thePinnedHostsAreTheAppsOwn() {
        #expect(BrowserPinnedHosts.hosts == [
            "moodle2.ntust.edu.tw", "ssoam2.ntust.edu.tw", "ssoam.ntust.edu.tw", "i.ntust.edu.tw", "mail.ntust.edu.tw",
            "api.lib.ntust.edu.tw", "cour01.ntust.edu.tw", "querycourse.ntust.edu.tw", "courseselection.ntust.edu.tw",
            "stuinfosys.ntust.edu.tw", "cardsystem.ntust.edu.tw", "studentpay.ntust.edu.tw",
        ])
        // Its sign-in gets the student id alone.
        #expect(!BrowserPinnedHosts.hosts.contains(Self.suggestionbox))
    }

    @Test("a pinned host's chain outside its pins is refused, though system trust takes it")
    func aPinnedHostIsHeldToItsPins() async throws {
        let pinning = TLSPinningDelegate(engine: F.engine(now: Self.date))
        let pinned = BrowserCertificateCheck(pinning: pinning, pinnedHosts: [Self.suggestionbox])
        #expect(try await evaluate(pinned, host: Self.suggestionbox) == .cancelAuthenticationChallenge)
        #expect(pinned.refusedHosts == [Self.suggestionbox])

        let moodle = "moodle2.ntust.edu.tw"
        let app = BrowserCertificateCheck(pinning: pinning)
        #expect(try await evaluate(app, host: moodle) == .cancelAuthenticationChallenge)
        #expect(app.refusedHosts == [moodle])
    }

    @Test("a pinned host named with a trailing dot is held to its pins, and its refusal and acceptance go by its plain name")
    func aTrailingDotNamesTheSameHost() async throws {
        let moodle = "moodle2.ntust.edu.tw", dotted = "moodle2.ntust.edu.tw."
        let check = BrowserCertificateCheck(pinning: TLSPinningDelegate(engine: F.engine(now: Self.date)))
        #expect(try await evaluate(check, host: dotted) == .cancelAuthenticationChallenge)
        #expect(check.refusedHosts == [moodle])

        let offer = check.offering(.certificate(host: moodle), at: URL(string: "https://\(dotted)/my/"))
        guard case .certificate(_, let refusal?) = offer else {
            Issue.record("no page to open at risk in \(offer)")
            return
        }
        #expect(try await evaluate(check.accepting(refusal), host: dotted) == .useCredential)
    }

    @Test("a browser-only host whose chain system trust refuses is offered to open at risk, in a store of its own")
    func anInvalidChainOnABrowserOnlyHostOffersTheRisk() async throws {
        let host = "sa.ntust.edu.tw"
        let invalid = try trust(Self.letsEncrypt, host: host)
        #expect(!SecTrustEvaluateWithError(invalid, nil))
        let page = BrowserPage()
        #expect(try await evaluate(page.certificates, host: host) == .performDefaultHandling)

        // WebKit's own check then fails the load.
        let refused = URL(string: "https://\(host)/page")!
        let error = NSError(domain: NSURLErrorDomain, code: NSURLErrorServerCertificateUntrusted, userInfo: [
            NSURLErrorFailingURLErrorKey: refused,
        ])
        let failure = try #require(BrowserPage.Failure.load(error, refusedHosts: page.certificates.refusedHosts))
        page.failure = page.certificates.offering(failure, at: BrowserPage.Failure.failingURL(of: error))
        let refusal = try #require(page.refusalToOpenAtRisk)
        #expect(refusal.url == refused)
        #expect(refusal.leaf == BrowserRiskAcceptance.leaf(of: invalid))

        page.openAtRisk()
        #expect(!page.store.isPersistent)
        #expect(try await evaluate(page.certificates, host: host) == .useCredential)
        #expect(try await evaluate(page.certificates, host: "stu.ntust.edu.tw") == .performDefaultHandling)
    }
}
#endif
