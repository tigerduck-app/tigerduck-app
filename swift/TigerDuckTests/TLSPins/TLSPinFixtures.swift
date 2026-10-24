import CryptoKit
import Foundation
import Security
@testable import TigerDuck

/// Signed documents, engines with their own storage and clock, and a hand-made `localhost` chain:
/// a leaf issued directly by a test root, with the leaf's key in a PKCS#12 (password `tigerduck`).
nonisolated enum TLSPinFixtures {
    static let keyID = "td-pins-test"
    static let signingKey = Curve25519.Signing.PrivateKey()
    static let keys = [keyID: signingKey.publicKey]
    static let now = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
    static let day: TimeInterval = 24 * 60 * 60

    static let ntustLeafSPKI = "Nz3wUtBXZ+2HPXuSyx4enXs62i/PH4MKtayV9N4X0PE="
    static let secureSSLCASPKI = "9VZ7Yd685RTXsE6rL/puuMbnejYaXwaZasGL7c+Uolc="
    static let globalRootSPKI = "xES1tmzl1x4bXkDyc4XJXL/SSgW1b3DKwJkvD1DDN5w="
    static let unknownSPKI = "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="

    static let testRootDER = Data(base64Encoded: "MIIBtDCCAVqgAwIBAgIUVQTsZtsVUdY9WwIZtcn6sk5Y6BcwCgYIKoZIzj0EAwIwODEYMBYGA1UECgwPVGlnZXJEdWNrIFRlc3RzMRwwGgYDVQQDDBNUaWdlckR1Y2sgVGVzdCBSb290MB4XDTI2MTAyNDIxMDAxN1oXDTQ2MTAxOTIxMDAxN1owODEYMBYGA1UECgwPVGlnZXJEdWNrIFRlc3RzMRwwGgYDVQQDDBNUaWdlckR1Y2sgVGVzdCBSb290MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAE9ytNHF7+/irw55OpKPLFWZydTWmnZJ7aT0UIO0oZwM4TaOVUjg2Sc9ltJiXPpc/1K/t5hq56hrVBGcPnOp6XG6NCMEAwHQYDVR0OBBYEFEk8kYCIyTNdTGiyzdKFFUEj0+N2MA8GA1UdEwEB/wQFMAMBAf8wDgYDVR0PAQH/BAQDAgEGMAoGCCqGSM49BAMCA0gAMEUCIDe94HQ4N318puD9f0TqrQ2iYgy3VYWNt9dLVB36jg6GAiEAky9gGQmaSwf8zKppS2tlirhfoGEBwspwlRu9Gpz58fE=")!
    static let testLeafDER = Data(base64Encoded: "MIIBmDCCAT+gAwIBAgIUQeYT0YmgXQnGidfIvimSoLYsY9owCgYIKoZIzj0EAwIwODEYMBYGA1UECgwPVGlnZXJEdWNrIFRlc3RzMRwwGgYDVQQDDBNUaWdlckR1Y2sgVGVzdCBSb290MB4XDTI2MTAyNDIxMDAxN1oXDTI5MDEwMTIxMDAxN1owFDESMBAGA1UEAwwJbG9jYWxob3N0MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEXoFzD+Qb5dXNAa+kDBBqHvVgo02Cv6hQW2FrsWYViXXYqPnYoCjs9kOj3qZ6NSxr8DY8ER8G83ygsQ0L+n/JrqNLMEkwDAYDVR0TAQH/BAIwADAOBgNVHQ8BAf8EBAMCB4AwEwYDVR0lBAwwCgYIKwYBBQUHAwEwFAYDVR0RBA0wC4IJbG9jYWxob3N0MAoGCCqGSM49BAMCA0cAMEQCIB6hSwCmqvqNWDI5yemiqQbLJ0k/lLnx7iH0Ad7553J9AiB7ySkDBVZP0ZpRwNF4RsrvNVW4I9UGELtnVcuYk6m+6A==")!
    static let testLeafPKCS12 = Data(base64Encoded: "MIIDogIBAzCCA2AGCSqGSIb3DQEHAaCCA1EEggNNMIIDSTCCAj8GCSqGSIb3DQEHBqCCAjAwggIsAgEAMIICJQYJKoZIhvcNAQcBMBwGCiqGSIb3DQEMAQMwDgQIJ2xHVIUJvvACAggAgIIB+JjyZgppbc2mnOAwgS2FA32ALemd/PZa+ZBQXakClpz3LnROd1xQUcASRPMnTTcbzMekaqE9trgX1rBAig3XzLLUHOoaIpFrP5wI+TJD3dW3UxusZhFWlhuhfimOAwcZfbbaYOeZ6hJ6GjzAOysO6OP1safSBNkW9fJF+NLYTjKJ9oxYnXtay/71GbEjIP1XPRBFTD3/864a9DPMimJ7b1Xu/wlqOcUymYy6ITKGxe4GF0qLIAiTZ2A3NOJdgLzq5P+SVJOHAX8WHD6rQkKHiisnoT+Ek/8VO5TUioFPvZq67YjoztRc299R6cSCFoO3JXFe2pPYja2SYaXgZNyWjFVCJpWtihB281yIvNEX2aItqEAwtrrhbCjYZwPT3u/Hn/8xXmrTNTkWp5CZunY/hbPah95AXmPb056H8Ex8QRUM5HqYZkudOTMB+3Sphk+G9r40fy5AQyhBpTqsXnFTTTxob9swqZicq57wqdBsism/9UuOE76CO2MfikIlV0EmSrueD4J2E7I3EwqzwRw1J/PpOd6IJREqkaVnE2OTZIz2PIlZgB47bgRo81Fj9OjInVo7gPt+GNJrhz1kcYG92nDcLKg9QVKJvpTKYkvnYZJg2ivhzDSLVzwnBB5MWnY9r2gj4AREYan4m+b/t+2kShupyHlEVh/kvzCCAQIGCSqGSIb3DQEHAaCB9ASB8TCB7jCB6wYLKoZIhvcNAQwKAQKggbQwgbEwHAYKKoZIhvcNAQwBAzAOBAgRh4XQbYDG7QICCAAEgZBelM8Ra9q8M3Z9nbcE2V0Bd+hWVMjobnAa/8RMIODTGnxvzsY3pccC4Gz1lTx3d9/AK5u10c2Qipn1hIx6GnR5vYoCKq4azmBDij9ktV29T7oDti4WyK7Oc79UrltBgiz02WZGdL3o0E5m9k3sYqaL/V48HNGSIjrnzVbnRgQwX3zAv06htlPpiB6I5Ny97fYxJTAjBgkqhkiG9w0BCRUxFgQUrH+hkor1yj0xZow/at6f8jLrGqQwOTAhMAkGBSsOAwIaBQAEFIUyEXSSMgjpTTAPso3I3lWpDBpDBBDa1uhk/IaemA2ETZPI6gp7AgIIAA==")!
    static let testLeafNotBefore = ISO8601DateFormatter().date(from: "2026-10-24T21:00:17Z")!

    static var testRoot: SecCertificate { SecCertificateCreateWithData(nil, testRootDER as CFData)! }
    static var testLeaf: SecCertificate { SecCertificateCreateWithData(nil, testLeafDER as CFData)! }

    static func defaults() -> UserDefaults {
        let name = "TLSPinTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    static func engine(
        builtIn: [TLSPinSet] = TLSPinTable.builtIn,
        baselineSerial: Int64 = 0,
        defaults: UserDefaults = defaults(),
        buildNumber: String = "100",
        now: Date = now
    ) -> TLSPinEngine {
        TLSPinEngine(
            builtIn: builtIn, baselineSerial: baselineSerial, keys: keys,
            defaults: defaults, buildNumber: buildNumber, clock: { now }
        )
    }

    static func set(
        _ id: String, domain: String, pins: [String], expiresAt: Date = now.addingTimeInterval(365 * day)
    ) -> [String: Any] {
        [
            "id": id,
            "domains": [["name": domain, "include_subdomains": true]],
            "pins": pins,
            "expires_at": ISO8601DateFormatter().string(from: expiresAt),
        ]
    }

    static func payload(
        serial: Int64 = 100,
        expiresAt: Date = now.addingTimeInterval(30 * day),
        sets: [[String: Any]] = [],
        promptRoots: [String] = [],
        format: Int = 1
    ) -> Data {
        let body: [String: Any] = [
            "format": format,
            "serial": serial,
            "issued_at": ISO8601DateFormatter().string(from: now),
            "expires_at": ISO8601DateFormatter().string(from: expiresAt),
            "pin_sets": sets,
            "prompt_roots": promptRoots,
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func envelope(
        _ payload: Data,
        keyID: String = keyID,
        format: Int = 1,
        signedBy key: Curve25519.Signing.PrivateKey = signingKey
    ) -> Data {
        let signature = try! key.signature(for: payload)
        let body: [String: Any] = [
            "format": format,
            "key_id": keyID,
            "payload": base64URL(payload),
            "signature": base64URL(signature),
        ]
        return try! JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// The chain system trust builds for `der` at `date`, leaf first up to its anchor.
    static func evaluatedChain(_ der: [[UInt8]], host: String, at date: Date) -> [SecCertificate]? {
        guard let trust = trust(der, host: host, at: date), SecTrustEvaluateWithError(trust, nil) else { return nil }
        return SecTrustCopyCertificateChain(trust) as? [SecCertificate]
    }

    static func trust(_ der: [[UInt8]], host: String, at date: Date) -> SecTrust? {
        let certificates = der.compactMap { SecCertificateCreateWithData(nil, Data($0) as CFData) }
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFArray, SecPolicyCreateSSL(true, host as CFString), &trust) == errSecSuccess,
              let trust else { return nil }
        SecTrustSetVerifyDate(trust, date as CFDate)
        SecTrustSetNetworkFetchAllowed(trust, false)
        return trust
    }
}

/// Records what the engine hands the prompt queue.
nonisolated final class TLSPinReports: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [TLSPinMismatch] = []

    var all: [TLSPinMismatch] { lock.withLock { stored } }

    func install(on engine: TLSPinEngine, refresh: (@Sendable () async -> Void)? = nil) {
        engine.install(refresh: refresh, report: { mismatch in self.lock.withLock { self.stored.append(mismatch) } })
    }
}
