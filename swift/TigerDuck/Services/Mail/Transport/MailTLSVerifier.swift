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

    /// - Parameter pinPolicy: test seam; `nil` reads `TLSPinningDelegate`'s table.
    static func verify(
        derChain: [[UInt8]],
        host: String,
        now: Date = Date(),
        pinPolicy: TLSPinningDelegate.PinPolicy? = nil
    ) -> Bool {
        let certificates = derChain.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        guard !certificates.isEmpty, certificates.count == derChain.count else { return false }

        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(certificates as CFArray, policy, &trust) == errSecSuccess,
              let trust else { return false }
        SecTrustSetVerifyDate(trust, now as CFDate)
        var error: CFError?
        guard SecTrustEvaluateWithError(trust, &error) else {
            logger.error("Mail TLS trust evaluation failed for \(host, privacy: .public)")
            return false
        }

        switch pinPolicy ?? TLSPinningDelegate.pinPolicy(forHost: host, now: now) {
        case .notPinned, .expired:
            return true
        case .pinned(let pins):
            let evaluated = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? certificates
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
