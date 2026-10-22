import Foundation
import CryptoKit
import os

final class TLSPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    static let shared = TLSPinningDelegate()

    struct PinSet {
        let hostSuffix: String
        let includeSubdomains: Bool
        let expiration: Date
        let pins: Set<String>
    }

    nonisolated static let pinSets: [PinSet] = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        func expiration(_ literal: String) -> Date {
            guard let date = formatter.date(from: literal) else {
                fatalError("TLSPinningDelegate: invalid expiration date literal \(literal)")
            }
            return date
        }
        return [
            // The *.ntust.edu.tw leaf and its TWCA Secure SSL CA, plus the TWCA SSL CA (TWCA CYBER
            // Root CA) that newer NTUST certificates come from, so a renewal from either works.
            PinSet(
                hostSuffix: "ntust.edu.tw",
                includeSubdomains: true,
                expiration: expiration("2027-08-18"),
                pins: [
                    "Nz3wUtBXZ+2HPXuSyx4enXs62i/PH4MKtayV9N4X0PE=",
                    "9VZ7Yd685RTXsE6rL/puuMbnejYaXwaZasGL7c+Uolc=",
                    "BxOmElsPeD54MBOb5h+TPNJnBlsAk6spRc/wLnko0cc=",
                ]
            ),
            // api.lib.ntust.edu.tw has its own pin set: the leaf, Sectigo DV E36, and Sectigo's roots
            // E46 and R46. Each renewal since 2022 changed the key and the issuer, and Sectigo now
            // issues only under these two roots, so the next certificate still matches.
            PinSet(
                hostSuffix: "api.lib.ntust.edu.tw",
                includeSubdomains: true,
                expiration: expiration("2027-05-04"),
                pins: [
                    "m8Epf0KqJFv9abCXfipePZ79hfOMjddCKxz+RSZIDKY=",
                    "ZSagvDzjltLkewXEBuDxIzpW/dpVw1Juvvmd0hhkzdY=",
                    "sLVjNUaFYfW7n6EtgBeEpjOlcnBdNPMrZDRF36iwBdE=",
                    "Douxi77vs4G+Ib/BogbTFymEYq0QSFXwSgVCaZcI09Q=",
                ]
            ),
        ]
    }()

    private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "Security.TLSPin"
    )

    nonisolated private static let staticLogger = Logger(
        subsystem: "org.ntust.app.TigerDuck",
        category: "Security.TLSPin"
    )

    enum PinPolicy: Equatable, Sendable {
        case notPinned
        case pinned(Set<String>)
        case expired
    }

    nonisolated static func pinPolicy(forHost host: String, now: Date = Date()) -> PinPolicy {
        guard let set = matchingPinSet(for: host) else { return .notPinned }
        return now >= set.expiration ? .expired : .pinned(set.pins)
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host

        guard let pinSet = Self.matchingPinSet(for: host) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if Date() >= pinSet.expiration {
            logger.fault(
                "TLS pin for \(host, privacy: .public) expired (\(pinSet.expiration, privacy: .public)) — falling back to system trust; rotate pins"
            )
            completionHandler(.performDefaultHandling, nil)
            return
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
        for cert in chain {
            guard let hash = Self.sha256SPKIBase64(of: cert) else { continue }
            if pinSet.pins.contains(hash) {
                completionHandler(.useCredential, URLCredential(trust: trust))
                return
            }
        }

        logger.error(
            "TLS pin mismatch for \(host, privacy: .public) — no chain SPKI matches; refusing connection"
        )
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    nonisolated private static func matchingPinSet(for host: String) -> PinSet? {
        // Strip a trailing dot: some resolver and proxy paths pass the FQDN
        // form (`ssoam2.ntust.edu.tw.`), which would miss both match branches
        // and silently fall through to system trust on a pinned host.
        var normalised = host.lowercased()
        if normalised.hasSuffix(".") { normalised.removeLast() }
        var best: PinSet?
        var bestLabelCount = 0
        for set in Self.pinSets {
            let suffix = set.hostSuffix.lowercased()
            let matches: Bool
            if set.includeSubdomains {
                matches = normalised == suffix
                    || normalised.hasSuffix("." + suffix)
            } else {
                matches = normalised == suffix
            }
            if matches {
                let labelCount = suffix.split(separator: ".").count
                if best == nil || labelCount > bestLabelCount {
                    best = set
                    bestLabelCount = labelCount
                }
            }
        }
        return best
    }

    nonisolated static func sha256SPKIBase64(of cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let spki = spkiData(from: key) else {
            return nil
        }
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    /// Reconstruct the DER-encoded SubjectPublicKeyInfo from a `SecKey`.
    /// `SecKeyCopyExternalRepresentation` returns the raw key bits, not the
    /// SPKI wrapper, so prepend the ASN.1 algorithm-identifier header for
    /// the key type.
    ///
    /// NTUST's certs are RSA 2048 (TWCA). EC P-256 and P-384 are wired in so
    /// the likely next algorithm migration needs no pinning code change. Any
    /// other key returns nil, so only that cert misses in the chain walk.
    nonisolated private static func spkiData(from key: SecKey) -> Data? {
        guard let attrs = SecKeyCopyAttributes(key) as? [String: Any],
              let keyType = attrs[kSecAttrKeyType as String] as? String,
              let keySize = attrs[kSecAttrKeySizeInBits as String] as? Int,
              let keyData = SecKeyCopyExternalRepresentation(key, nil) as Data? else {
            return nil
        }
        let rsa = kSecAttrKeyTypeRSA as String
        let ec = kSecAttrKeyTypeECSECPrimeRandom as String
        let header: [UInt8]
        switch (keyType, keySize) {
        case (rsa, 2048):
            header = [
                0x30, 0x82, 0x01, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86,
                0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
                0x82, 0x01, 0x0f, 0x00,
            ]
        case (rsa, 4096):
            header = [
                0x30, 0x82, 0x02, 0x22, 0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86,
                0x48, 0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00, 0x03,
                0x82, 0x02, 0x0f, 0x00,
            ]
        case (ec, 256):
            header = [
                0x30, 0x59, 0x30, 0x13, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce,
                0x3d, 0x02, 0x01, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d,
                0x03, 0x01, 0x07, 0x03, 0x42, 0x00,
            ]
        case (ec, 384):
            header = [
                0x30, 0x76, 0x30, 0x10, 0x06, 0x07, 0x2a, 0x86, 0x48, 0xce,
                0x3d, 0x02, 0x01, 0x06, 0x05, 0x2b, 0x81, 0x04, 0x00, 0x22,
                0x03, 0x62, 0x00,
            ]
        default:
            staticLogger.fault(
                "TLS pin: unsupported key (type=\(keyType, privacy: .public), bits=\(keySize, privacy: .public)) — add SPKI header to spkiData or this cert is silently skipped during chain walk"
            )
            return nil
        }
        var spki = Data(header)
        spki.append(keyData)
        return spki
    }
}
