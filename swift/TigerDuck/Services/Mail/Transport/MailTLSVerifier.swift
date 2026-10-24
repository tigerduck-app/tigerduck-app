#if os(iOS)
import Foundation
import Security
import os

/// Certificate check for the School Mail IMAP and SMTP connections, by `TLSPinningDelegate`'s
/// rules. A refused chain fails this connection at once; the next connect uses the pins the
/// refresh it starts brings. The `SecTrust` evaluation is the connection's only validation: a
/// custom NIOSSL callback replaces all of BoringSSL's checks, hostname included, and on Darwin
/// also NIOSSL's Security.framework callback; `.fullVerification` in `MailTransportSecurity` only
/// keeps it from being skipped. See docs/decisions/0025-remote-tls-pins.md.
nonisolated enum MailTLSVerifier {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.TLS")

    /// `now` is the trust evaluation's date; the pins' expiry follows the engine's clock. Runs
    /// `SecTrustEvaluateWithError`, which can block; SwiftMail's custom verification callback,
    /// the only production caller, invokes this on the connection's own NIO event loop.
    static func verify(
        derChain: [[UInt8]],
        host: String,
        now: Date = Date(),
        engine: TLSPinEngine = .shared
    ) -> Bool {
        // NIOSSL hands the peer chain leaf-first (TLS wire order), and the order matters:
        // `SecTrustCreateWithCertificates` takes the first certificate as the leaf, so anything
        // else first would evaluate trust against the wrong certificate.
        let certificates = derChain.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        guard !certificates.isEmpty, certificates.count == derChain.count else {
            logger.error("Mail TLS certificate parsing failed for \(host, privacy: .public)")
            return false
        }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust else {
            logger.error("Mail TLS trust object creation failed for \(host, privacy: .public)")
            return false
        }
        SecTrustSetVerifyDate(trust, now as CFDate)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            let code = error.map { String(CFErrorGetCode($0)) } ?? "unknown"
            let description = error.map { String(describing: $0) } ?? "unknown"
            logger.error(
                "Mail TLS trust evaluation failed for \(host, privacy: .public), code \(code, privacy: .public): \(description, privacy: .private(mask: .hash))"
            )
            return false
        }

        let evaluated = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        guard case .refused = engine.evaluate(host: host, chain: evaluated) else { return true }
        logger.error("Mail TLS pin mismatch for \(host, privacy: .public)")
        Task { _ = await engine.resolveRefusal(host: host, chain: evaluated) }
        return false
    }
}
#endif
