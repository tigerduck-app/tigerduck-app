import CryptoKit
import Foundation
import Security

/// The refused certificates the student opened anyway in one browser. An acceptance holds for its
/// host and the leaf that host served when it was refused, in memory, until the browser closes.
/// It reaches only that browser's web view, never the app's own requests.
struct BrowserRiskAcceptance {
    /// The acceptances of every browser since launch, which only ever refuse. WebKit may carry a
    /// later browser's page over a connection an earlier one accepted, or resume its TLS session,
    /// without asking about the certificate again.
    final class Launch {
        static let shared = Launch()
        fileprivate var accepted: Set<Served> = []
    }

    fileprivate struct Served: Hashable {
        let host: String
        let leaf: String

        init(_ host: String, _ leaf: String) {
            self.host = host.lowercased()
            self.leaf = leaf
        }
    }

    private let launch: Launch
    private var lastServed: [String: String] = [:]
    private var accepted: Set<Served> = []
    private var letThrough: Set<Served> = []

    init(launch: Launch = .shared) {
        self.launch = launch
    }

    /// Notes a leaf the browser's certificate check saw, and whether the check let it through.
    mutating func checked(_ leaf: String, from host: String, letThrough passed: Bool) {
        lastServed[host.lowercased()] = leaf
        if passed { letThrough.insert(Served(host, leaf)) }
    }

    func canAccept(host: String) -> Bool { lastServed[host.lowercased()] != nil }

    /// Accepts the leaf the host served last.
    mutating func accept(host: String) {
        guard let leaf = lastServed[host.lowercased()] else { return }
        accepted.insert(Served(host, leaf))
        launch.accepted.insert(Served(host, leaf))
    }

    func allows(_ leaf: String?, from host: String) -> Bool {
        leaf.map { accepted.contains(Served(host, $0)) } ?? false
    }

    /// Whether a page arrived with a leaf another browser accepted and this one never checked.
    func refusesUnchecked(_ leaf: String, from host: String) -> Bool {
        let served = Served(host, leaf)
        return launch.accepted.contains(served) && !accepted.contains(served) && !letThrough.contains(served)
    }

    /// The SHA-256 of the leaf's DER, as hex.
    static func leaf(of trust: SecTrust?) -> String? {
        guard let trust, let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The browser's certificate check: `TLSPinningDelegate` for pins and system trust, the hosts it
/// refused, and the certificates the student opened anyway.
@Observable
final class BrowserCertificateCheck {
    var acceptance: BrowserRiskAcceptance
    @ObservationIgnored private(set) var refusedHosts: Set<String> = []

    init(acceptance: BrowserRiskAcceptance = BrowserRiskAcceptance()) {
        self.acceptance = acceptance
    }

    func evaluate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @MainActor @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let host = challenge.protectionSpace.host
        let trust = challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust
            ? challenge.protectionSpace.serverTrust : nil
        let leaf = BrowserRiskAcceptance.leaf(of: trust)
        if let trust, acceptance.allows(leaf, from: host) {
            refusedHosts.remove(host)
            completionHandler(.useCredential, URLCredential(trust: trust))
            return
        }
        TLSPinningDelegate.shared.evaluate(challenge) { disposition, credential in
            Task { @MainActor in
                if disposition == .cancelAuthenticationChallenge { self.refusedHosts.insert(host) }
                if let leaf { self.acceptance.checked(leaf, from: host, letThrough: disposition == .useCredential) }
                completionHandler(disposition, credential)
            }
        }
    }

    /// The host of a page that came over a connection a closed browser accepted, which reached no
    /// check here: it is refused again until this browser accepts it.
    func refusedUnchecked(host: String?, trust: SecTrust?) -> String? {
        guard let host, let leaf = BrowserRiskAcceptance.leaf(of: trust),
              acceptance.refusesUnchecked(leaf, from: host) else { return nil }
        refusedHosts.insert(host)
        acceptance.checked(leaf, from: host, letThrough: false)
        return host
    }
}
