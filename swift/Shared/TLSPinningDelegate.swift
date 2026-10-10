import Foundation
import CryptoKit
import os

/// URLSession server-trust delegate that pins SPKI SHA-256 hashes. Install it on
/// every session that carries NTUST SSO credentials, the Moodle `wstoken` or
/// `privatetoken`, or the library bearer token; pins and expirations match the
/// Android app. Hosts outside the pin table fall through to system trust, and an
/// expired pin set falls back to system trust instead of failing.
/// `@unchecked Sendable`: URLSession calls it on arbitrary serial queues, and the
/// only mutable state, the pin table, is built once at type load.
/// See docs/decisions/0001-tls-pinning.md.
final class TLSPinningDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {

    /// Shared instance — URLSession retains its delegate, so handing
    /// the same singleton to every pinned session keeps the object
    /// count to one without any state-sharing concerns (the pin table
    /// is immutable + static).
    static let shared = TLSPinningDelegate()

    private struct PinSet {
        /// Bare host suffix without leading dot. For exact-match-only
        /// hosts set `includeSubdomains = false`.
        let hostSuffix: String
        let includeSubdomains: Bool
        /// Absolute date after which the pin set goes inert (fail-soft
        /// fallback to system trust).
        let expiration: Date
        /// Base64-encoded SHA-256 of SubjectPublicKeyInfo DER. Include
        /// leaf + intermediate so a TWCA-side leaf rotation that keeps
        /// the same intermediate does NOT immediately break the app.
        let pins: Set<String>
    }

    /// Pins lifted verbatim from `tigerduck-app-android`'s
    /// `network_security_config.xml`. Keep both repos updated together
    /// at every rotation — diverging pin sets means one platform
    /// breaks before the other.
    nonisolated private static let pinSets: [PinSet] = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        guard let expiration = formatter.date(from: "2027-01-18") else {
            fatalError("TLSPinningDelegate: invalid expiration date literal")
        }
        return [
            // *.ntust.edu.tw — TWCA Secure SSL Certification Authority.
            // Covers ssoam2, moodle2, courseselection, stuinfosys, etc.
            PinSet(
                hostSuffix: "ntust.edu.tw",
                includeSubdomains: true,
                expiration: expiration,
                pins: [
                    "Nz3wUtBXZ+2HPXuSyx4enXs62i/PH4MKtayV9N4X0PE=",
                    "9VZ7Yd685RTXsE6rL/puuMbnejYaXwaZasGL7c+Uolc=",
                ]
            ),
            // api.lib.ntust.edu.tw — distinct chain from the rest of
            // the *.ntust.edu.tw zone, hence its own pin set.
            PinSet(
                hostSuffix: "api.lib.ntust.edu.tw",
                includeSubdomains: true,
                expiration: expiration,
                pins: [
                    "m8Epf0KqJFv9abCXfipePZ79hfOMjddCKxz+RSZIDKY=",
                    "ZSagvDzjltLkewXEBuDxIzpW/dpVw1Juvvmd0hhkzdY=",
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

    /// What the pin table says about `host`, for TLS stacks that do not go through
    /// URLSession (the School Mail IMAP/SMTP connections, see `MailTLSVerifier`).
    enum PinPolicy: Equatable, Sendable {
        case notPinned
        case pinned(Set<String>)
        /// The host's pin set is past its expiration date: fall back to system trust,
        /// exactly as `urlSession(_:didReceive:completionHandler:)` does.
        case expired
    }

    nonisolated static func pinPolicy(forHost host: String, now: Date = Date()) -> PinPolicy {
        guard let set = matchingPinSet(for: host) else { return .notPinned }
        return now >= set.expiration ? .expired : .pinned(set.pins)
    }

    // MARK: - URLSessionDelegate

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
            // Host not in scope (analytics, app's own backend, etc.)
            // — defer to system trust. Safe to install on mixed-host
            // sessions for that reason.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if Date() >= pinSet.expiration {
            // Fail soft: bricking a stale build is worse than falling back to
            // system trust. `.fault`, not `.warning`, so Console and sysdiagnose
            // flag it; a missed rotation shows nowhere else and silently drops MITM defence.
            logger.fault(
                "TLS pin for \(host, privacy: .public) expired (\(pinSet.expiration, privacy: .public)) — falling back to system trust; rotate pins"
            )
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // SPKI pinning is additive: system chain must still pass
        // (validity window, EV, OCSP/CRL as configured) — pinning
        // only narrows which valid chains are acceptable.
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

        // Any cert in the chain (leaf, intermediate or root) whose SPKI hash
        // is pinned satisfies the pin, as with Android's `pin-set`. Pinning the
        // leaf and its issuing CA keeps a leaf rotation on the same CA valid.
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

    // MARK: - Internals

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
                // Most specific match wins by label count, not character count:
                // `api.lib.ntust.edu.tw` (5) beats `ntust.edu.tw` (3). Character count
                // could mis-rank a short-label sibling on the library's chain.
                let labelCount = suffix.split(separator: ".").count
                if best == nil || labelCount > bestLabelCount {
                    best = set
                    bestLabelCount = labelCount
                }
            }
        }
        return best
    }

    /// Compute base64(SHA-256(SPKI DER)) for `cert`. Returns `nil` for
    /// any key algorithm the SPKI-header table below does not cover —
    /// caller continues walking the chain rather than failing the
    /// connection on a single unsupported cert.
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
        // CFString-to-String bridge happens once so the switch below
        // pattern-matches on Swift strings, not CFString constants.
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
            // `.fault`: a silent miss looks like a generic pin mismatch, which
            // sends triage after the wrong cause and delays fixing `spkiData`.
            // Logging the key type and size points at the missing header entry.
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
