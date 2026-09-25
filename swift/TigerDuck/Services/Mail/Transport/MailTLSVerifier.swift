#if os(iOS)
import Foundation
import Security
import os

/// Certificate check for the School Mail IMAP and SMTP connections.
///
/// The same rules as `TLSPinningDelegate`: the system chain and the hostname must pass
/// first; then some certificate's SPKI must be in the host's pin set. After the pin set's
/// expiration date the check falls back to system trust alone (fail-soft, issue #92).
/// There is no way to bypass a failure (design doc §7.1).
///
/// - Important: the chain and hostname evaluation below is not belt-and-braces over something
///   NIOSSL is also doing. Installing a `NIOSSLCustomVerificationCallback` **replaces** all of
///   BoringSSL's verification, hostname checking included, and on Darwin it overwrites the
///   Security.framework callback NIOSSL installs in `NIOSSLContext.createConnection()`.
///   `.fullVerification` in `MailTransportSecurity` only keeps the callback from being skipped.
///   So `SecTrustCreateWithCertificates` + `SecPolicyCreateSSL(true, host)` +
///   `SecTrustEvaluateWithError` here *are* the connection's only validation — remove them for
///   a pin-only check and School Mail accepts any chain from any issuer for any name.
nonisolated enum MailTLSVerifier {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.TLS")

    /// - Parameter pinPolicy: test seam; `nil` reads `TLSPinningDelegate`'s table. Never pass
    ///   `.notPinned` from production code — it exists only so tests can force the unpinned path.
    /// - Note: Runs `SecTrustEvaluateWithError`, which can block; SwiftMail's custom
    ///   verification callback (the only production caller, via `swiftMailVerifier`) already
    ///   invokes this off the main thread, on the IMAP/SMTP connection's own NIO event loop.
    static func verify(
        derChain: [[UInt8]],
        host: String,
        now: Date = Date(),
        pinPolicy: TLSPinningDelegate.PinPolicy? = nil
    ) -> Bool {
        // NIOSSL hands the peer chain leaf-first (TLS wire order), and that order is load-
        // bearing here, not just a logging nicety: `SecTrustCreateWithCertificates` treats the
        // first certificate in its input array as the leaf when building the trust chain, so
        // passing anything else first would evaluate trust against the wrong certificate.
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
            // The numeric CFError code identifies no one and is safe to log in the clear
            // (unlike the full description, which can carry hostnames or paths); it also
            // survives independently of whether the description's `.private(mask: .hash)`
            // hides anything actionable in a bug report.
            let code = error.map { String(CFErrorGetCode($0)) } ?? "unknown"
            let description = error.map { String(describing: $0) } ?? "unknown"
            logger.error(
                "Mail TLS trust evaluation failed for \(host, privacy: .public), code \(code, privacy: .public): \(description, privacy: .private(mask: .hash))"
            )
            return false
        }

        switch pinPolicy ?? TLSPinningDelegate.pinPolicy(forHost: host, now: now) {
        case .notPinned:
            return true
        case .expired:
            logger.fault("Mail TLS pins expired for \(host, privacy: .public); falling back to system trust")
            return true
        case .pinned(let pins):
            // The chain Security.framework actually evaluated and trusts — never the
            // caller-supplied `certificates`, which haven't been through trust evaluation
            // and could include something the evaluation dropped or never trusted.
            let evaluated = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
            let matched = evaluated.contains { certificate in
                TLSPinningDelegate.sha256SPKIBase64(of: certificate).map(pins.contains) ?? false
            }
            if !matched {
                logger.error("Mail TLS pin mismatch for \(host, privacy: .public)")
            }
            return matched
        }
    }
}
#endif
