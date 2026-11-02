import CryptoKit
import Foundation
import Security

/// The refused certificates the student opened anyway in one browser, each the leaf its host served
/// when the page was refused. Each acceptance opens a store of its own (`BrowserPage.openAtRisk`),
/// so it reaches only the web view on that store, never the app's own requests or another browser.
struct BrowserRiskAcceptance {
    /// A page refused for its certificate: its address and the leaf its host served at the refusal.
    struct Refusal: Equatable {
        let url: URL
        let leaf: String

        var host: String { BrowserRouting.host(of: url) ?? "" }
    }

    private struct Served: Hashable {
        let host: String
        let leaf: String
    }

    private var accepted: Set<Served> = []

    func accepting(_ refusal: Refusal) -> Self {
        var acceptance = self
        acceptance.accepted.insert(Served(host: refusal.host, leaf: refusal.leaf))
        return acceptance
    }

    func allows(_ leaf: String?, from host: String) -> Bool {
        leaf.map { accepted.contains(Served(host: TLSPinMatcher.hostName(host), leaf: $0)) } ?? false
    }

    /// The SHA-256 of the leaf's DER, as hex.
    static func leaf(of trust: SecTrust?) -> String? {
        guard let trust, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// One web view's certificate check: `TLSPinningDelegate` for the hosts the app signs in to, the
/// system's trust store for every other, the hosts it refused with the leaf each served then, and
/// the refused leaves the student opened anyway.
final class BrowserCertificateCheck {
    let acceptance: BrowserRiskAcceptance
    private(set) var refusedHosts: Set<String> = []
    private var refusedLeaves: [String: String] = [:]
    private let pinning: TLSPinningDelegate
    private let pinnedHosts: Set<String>

    init(
        acceptance: BrowserRiskAcceptance = BrowserRiskAcceptance(),
        pinning: TLSPinningDelegate = .shared,
        pinnedHosts: Set<String> = BrowserPinnedHosts.hosts
    ) {
        self.acceptance = acceptance
        self.pinning = pinning
        self.pinnedHosts = pinnedHosts
    }

    /// The same check, letting `refusal`'s leaf through as well.
    func accepting(_ refusal: BrowserRiskAcceptance.Refusal) -> BrowserCertificateCheck {
        BrowserCertificateCheck(acceptance: acceptance.accepting(refusal), pinning: pinning, pinnedHosts: pinnedHosts)
    }

    func evaluate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // WebKit names a host as its address does, so `moodle2.ntust.edu.tw.` keeps its dot.
        let host = TLSPinMatcher.hostName(challenge.protectionSpace.host)
        let trust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? challenge.protectionSpace.serverTrust : nil
        let leaf = BrowserRiskAcceptance.leaf(of: trust)
        if let trust, acceptance.allows(leaf, from: host) {
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        guard pinnedHosts.contains(host) else {
            if let leaf { notLetThrough(leaf, from: host) }
            completionHandler(.performDefaultHandling, nil)
            return
        }
        pinning.evaluate(challenge) { disposition, credential in
            Task { @MainActor in
                if disposition == .cancelAuthenticationChallenge { self.refusedHosts.insert(host) }
                // System trust may still refuse what the pins hand on, so each leaf not let through counts.
                if disposition != .useCredential, let leaf { self.notLetThrough(leaf, from: host) }
                completionHandler(disposition, credential)
            }
        }
    }

    /// Notes the leaf a host served in a challenge this check did not let through itself.
    func notLetThrough(_ leaf: String, from host: String) {
        refusedLeaves[TLSPinMatcher.hostName(host)] = leaf
    }

    /// The failure with the page the student may open at risk, when it is a certificate's: the
    /// address that failed and the leaf its host served at the refusal.
    func offering(_ failure: BrowserPage.Failure, at failingURL: URL?) -> BrowserPage.Failure {
        guard case .certificate(let host, _) = failure, let failingURL,
              let leaf = refusedLeaves[BrowserRouting.host(of: failingURL) ?? ""] else { return failure }
        return .certificate(host: host, refusal: BrowserRiskAcceptance.Refusal(url: failingURL, leaf: leaf))
    }
}
