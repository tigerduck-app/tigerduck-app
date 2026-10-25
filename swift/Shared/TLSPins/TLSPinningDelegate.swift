import Foundation
import Security
import os

/// Applies `TLSPinEngine` to every session that carries NTUST or library secrets. Hosts outside
/// the pin sets fall through to system trust, so it is safe on a session that reaches other hosts.
/// See docs/decisions/0025-remote-tls-pins.md.
nonisolated final class TLSPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    static let shared = TLSPinningDelegate()

    private let engine: TLSPinEngine
    private let testTrust: (anchors: [SecCertificate], date: Date)?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Security.TLSPin")

    init(engine: TLSPinEngine = .shared) {
        self.engine = engine
        self.testTrust = nil
    }

    #if DEBUG
    /// Tests evaluate a hand-made chain against their own root, at a date inside its validity.
    init(engine: TLSPinEngine, testAnchors: [SecCertificate], verifyDate: Date) {
        self.engine = engine
        self.testTrust = (testAnchors, verifyDate)
    }
    #endif

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        evaluate(challenge, completionHandler: completionHandler)
    }

    /// The same check for a challenge that comes from no URLSession, such as a web view's.
    func evaluate(
        _ challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        switch engine.policy(forHost: host) {
        case .notPinned:
            completionHandler(.performDefaultHandling, nil)
            return
        case .expired(let set):
            logger.fault("TLS pins for \(set.id, privacy: .public) expired; \(host, privacy: .public) falls back to system trust")
            completionHandler(.performDefaultHandling, nil)
            return
        case .pinned:
            break
        }

        if let testTrust {
            SecTrustSetAnchorCertificates(trust, testTrust.anchors as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            SecTrustSetVerifyDate(trust, testTrust.date as CFDate)
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            // The CFError description can carry the attacker cert's subject and
            // issuer via `NSUnderlyingError`. Hash it so those details stay out
            // of Console and sysdiagnose; the host alone stays readable.
            logger.error(
                "TLS trust evaluation failed for \(host, privacy: .public): \(String(describing: trustError), privacy: .private(mask: .hash))"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        let credential = URLCredential(trust: trust)
        guard case .refused = engine.evaluate(host: host, chain: chain) else {
            completionHandler(.useCredential, credential)
            return
        }
        // The handshake waits here, so a document fetched now lets this same request through.
        let engine = engine
        Task {
            let allowed = await engine.resolveRefusal(host: host, chain: chain)
            completionHandler(allowed ? .useCredential : .cancelAuthenticationChallenge, allowed ? credential : nil)
        }
    }
}
