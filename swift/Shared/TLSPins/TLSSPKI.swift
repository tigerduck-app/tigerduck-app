import CryptoKit
import Foundation
import Security
import os

nonisolated enum TLSSPKI {
    private static let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Security.TLSPin")

    /// Base64 SHA-256 of the certificate's SubjectPublicKeyInfo DER, the value pin sets hold.
    static func sha256Base64(of cert: SecCertificate) -> String? {
        guard let key = SecCertificateCopyKey(cert),
              let spki = spkiData(from: key) else {
            return nil
        }
        return Data(SHA256.hash(data: spki)).base64EncodedString()
    }

    static func sha256Base64(ofDER der: Data) -> String? {
        SecCertificateCreateWithData(nil, der as CFData).flatMap(sha256Base64(of:))
    }

    /// Reconstruct the DER-encoded SubjectPublicKeyInfo from a `SecKey`.
    /// `SecKeyCopyExternalRepresentation` returns the raw key bits, not the
    /// SPKI wrapper, so prepend the ASN.1 algorithm-identifier header for
    /// the key type.
    ///
    /// RSA 2048 and 4096 and EC P-256 and P-384 cover the TWCA and Sectigo chains. Any other key
    /// returns nil, so only that cert misses in the chain walk.
    private static func spkiData(from key: SecKey) -> Data? {
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
