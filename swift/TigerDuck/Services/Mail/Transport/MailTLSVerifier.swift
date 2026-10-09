#if os(iOS)
import Foundation
import Security
import os

/// Certificate check for the School Mail IMAP and SMTP connections. Same rules as
/// `TLSPinningDelegate`: the system chain and hostname must pass, then some certificate's SPKI
/// must be in the host's pin set; after the pin set expires, system trust alone decides
/// (fail-soft, issue #92). A failure cannot be bypassed. The `SecTrust` evaluation below is the
/// connection's only validation: a custom NIOSSL callback replaces all of BoringSSL's checks,
/// hostname included, and on Darwin also the Security.framework callback NIOSSL installs;
/// `.fullVerification` in `MailTransportSecurity` only keeps it from being skipped. Without the
/// evaluation, any chain passes for any name. See docs/decisions/0001-tls-pinning.md.
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
            // The numeric CFError code identifies no one, so it is logged in the clear; the
            // description can carry hostnames or paths and is hashed. The code stays useful in a
            // bug report even when the hash hides everything actionable.
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
