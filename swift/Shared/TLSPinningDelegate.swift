import Foundation
import CryptoKit
import os

/// SPKI-pinned URLSession server-trust delegate for the hosts that
/// receive NTUST SSO credentials, the long-lived Moodle `wstoken`, and
/// the library bearer token.
///
/// Mirrors Android's `app/src/main/res/xml/network_security_config.xml`
/// (`tigerduck-app-android` repo) — same pin set, same expirations.
/// Threat model assumed there: campus Wi-Fi with a hostile MDM root CA
/// pushed into the device trust store; system CA chain would accept it,
/// so a per-host SPKI check is required to refuse the MITM.
///
/// **Why programmatic instead of ATS `NSPinnedDomains`?** We tested
/// both. `NSPinnedDomains` is the natural fit (declarative, single
/// Info.plist key) but has no fail-soft expiration mechanism, and
/// empirically a delegate's `useCredential(URLCredential(trust:))`
/// CANNOT override a pin rejection — Apple enforces the check at a
/// layer beneath `URLSessionDelegate`. Issue #92 calls for Android-
/// style fail-soft after the pin set's expiration date (so users on
/// un-updated builds don't get bricked when TWCA rotates the chain),
/// which requires runtime control. Hence: delegate.
///
/// After a pin set's expiration date the delegate falls back to system
/// trust evaluation rather than hard-failing — matches Android's
/// `expiration` attribute semantics. Pin rotation discipline is
/// enforced by release process: a release-calendar reminder fires
/// before the expiration date to ship a new build with rotated pins.
/// The `logger.warning` on the post-expiry path surfaces stale pins to
/// system log so QA / monitoring catches a missed rotation.
///
/// Pin material is the SHA-256 of the SubjectPublicKeyInfo DER, the
/// same value Android's `pin-set` accepts. Generate with:
/// ```
/// echo | openssl s_client -servername HOST -connect HOST:443 -showcerts \
///   | openssl x509 -noout -pubkey \
///   | openssl pkey -pubin -outform der \
///   | openssl dgst -sha256 -binary \
///   | openssl enc -base64
/// ```
///
/// Wire onto any `URLSession` that posts NTUST SSO credentials, the
/// Moodle wstoken / privatetoken, or library bearer tokens. Hosts
/// outside the pin map fall through to system trust, so it's safe to
/// install on a session that also talks to non-pinned hosts.
///
/// The class is `@unchecked Sendable` because URLSession invokes the
/// challenge handler from arbitrary serial queues; the only mutable
/// state in the file is the pin table built once at type load time.
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
    private static let pinSets: [PinSet] = {
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

        guard let pinSet = matchingPinSet(for: host) else {
            // Host not in scope (analytics, app's own backend, etc.)
            // — defer to system trust. Safe to install on mixed-host
            // sessions for that reason.
            completionHandler(.performDefaultHandling, nil)
            return
        }

        if Date() >= pinSet.expiration {
            // Fail-soft per the issue's acceptance criteria. Bricking
            // a stale build is worse than reverting to system trust.
            // `.fault` (not `.warning`) so sysdiagnose / Console flags
            // this prominently — missed rotations have no other in-app
            // surface, and stale-pin builds silently lose MITM defence.
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
            // CFError describe can carry the attacker cert's subject/
            // issuer via `NSUnderlyingError`. Hash it so the host stays
            // operationally useful but cert details don't leak into
            // Console / sysdiagnose attachments.
            logger.error(
                "TLS trust evaluation failed for \(host, privacy: .public): \(String(describing: trustError), privacy: .private(mask: .hash))"
            )
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }

        // Walk the chain — any cert (leaf, intermediate, or root)
        // whose SPKI hash is in the pin set satisfies the pin. This
        // mirrors Android's `pin-set` semantics: include both leaf +
        // issuing CA so leaf rotation that keeps the same intermediate
        // continues to validate.
        let chain = (SecTrustCopyCertificateChain(trust) as? [SecCertificate]) ?? []
        for cert in chain {
            guard let hash = sha256SPKIBase64(of: cert) else { continue }
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

    private func matchingPinSet(for host: String) -> PinSet? {
        // Strip a trailing dot — some resolver / proxy paths inject
        // FQDN form (`ssoam2.ntust.edu.tw.`) which would otherwise
        // miss both the equality and the `.suffix` suffix branches and
        // silently fall through to system trust on a pinned host.
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
                // Most-specific match wins on LABEL count, not raw
                // character count: `api.lib.ntust.edu.tw` has 5 labels
                // vs `ntust.edu.tw`'s 3, so the library set is picked
                // for the library host. Character-count tiebreaking
                // would mis-rank a hypothetical short-label sibling
                // sharing the library's distinct chain.
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
    private func sha256SPKIBase64(of cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let spki = spkiData(from: key) else {
            return nil
        }
        let digest = SHA256.hash(data: spki)
        return Data(digest).base64EncodedString()
    }

    /// Reconstruct the DER-encoded SubjectPublicKeyInfo from a `SecKey`.
    /// `SecKeyCopyExternalRepresentation` returns the raw key bits, not
    /// the SPKI wrapper, so we prepend the well-known ASN.1
    /// algorithm-identifier header for the matching key type.
    ///
    /// Today's NTUST certs are RSA 2048 (TWCA); EC P-256/P-384 are
    /// pre-wired so the obvious next algorithm migration does not
    /// require a pinning code change. Anything else returns nil and
    /// degrades to a chain-walk miss on that cert specifically.
    private func spkiData(from key: SecKey) -> Data? {
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
            // `.fault` because a silent miss here mimics a generic pin
            // mismatch — triage starts from the wrong hypothesis and
            // delays rotating the spkiData table. Logging the type +
            // size points straight at the missing header entry.
            logger.fault(
                "TLS pin: unsupported key (type=\(keyType, privacy: .public), bits=\(keySize, privacy: .public)) — add SPKI header to spkiData or this cert is silently skipped during chain walk"
            )
            return nil
        }
        var spki = Data(header)
        spki.append(keyData)
        return spki
    }
}
