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
        // NIOSSL hands the peer chain leaf-first (TLS wire order); this only matters for
        // logging context here, since the pin check below scans every certificate in the
        // chain the platform actually evaluated, not just the first.
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
            let description = error.map { String(describing: $0) } ?? "unknown"
            logger.error("Mail TLS trust evaluation failed for \(host, privacy: .public): \(description, privacy: .private(mask: .hash))")
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
