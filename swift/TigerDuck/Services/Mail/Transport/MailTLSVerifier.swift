#if os(iOS)
import Foundation
import Security
import os

nonisolated enum MailTLSVerifier {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Mail.TLS")

    static func verify(
        derChain: [[UInt8]],
        host: String,
        now: Date = Date(),
        pinPolicy: TLSPinningDelegate.PinPolicy? = nil
    ) -> Bool {
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

        switch pinPolicy ?? TLSPinningDelegate.pinPolicy(forHost: host, now: now) {
        case .notPinned:
            return true
        case .expired:
            logger.fault("Mail TLS pins expired for \(host, privacy: .public); falling back to system trust")
            return true
        case .pinned(let pins):
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
