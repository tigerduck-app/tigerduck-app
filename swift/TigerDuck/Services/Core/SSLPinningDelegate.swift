import CommonCrypto
import Foundation
import Security

/// URLSession delegate that enforces SPKI (Subject Public Key Info) pinning
/// for `api.tigerduck.app`. Connections to other hosts pass through to the
/// system trust evaluator unchanged.
///
/// Why pin the intermediate, not the leaf: the leaf cert rotates every ~90
/// days (Google Trust Services / ACME). Pinning it would brick the app on
/// renewal. The intermediate CA key is stable across rotations.
///
/// Debug builds skip pinning so local dev servers (localhost, LAN IPs)
/// work without custom certs.
final class SSLPinningDelegate: NSObject, URLSessionDelegate, Sendable {
    static let shared = SSLPinningDelegate()

    private static let pinnedHost = "api.tigerduck.app"

    // SPKI SHA-256 hashes (base64). Any match passes.
    // Intermediate: Google Trust Services WE1 (signs the leaf)
    // Leaf: current api.tigerduck.app cert (backup)
    private static let pinnedSPKIHashes: Set<String> = [
        "kIdp6NNEd8wsugYyyIYFsi1ylMCED3hZbSR8ZFsa/A4=", // GTS WE1 intermediate
        "l/nhowDuwPyl0AGaN0beCU1kR/YwP2J/nvXo8bttSOM=", // api.tigerduck.app leaf
    ]

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let serverTrust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        let host = challenge.protectionSpace.host
        guard host == Self.pinnedHost else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        #if DEBUG
        completionHandler(.performDefaultHandling, nil)
        return
        #else
        guard evaluatePins(serverTrust: serverTrust) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: serverTrust))
        #endif
    }

    private func evaluatePins(serverTrust: SecTrust) -> Bool {
        let policy = SecPolicyCreateSSL(true, Self.pinnedHost as CFString)
        SecTrustSetPolicies(serverTrust, policy)

        var error: CFError?
        guard SecTrustEvaluateWithError(serverTrust, &error) else {
            return false
        }

        let certCount = SecTrustGetCertificateCount(serverTrust)
        guard certCount > 0 else { return false }

        // Check every cert in the chain against pinned hashes.
        if let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate] {
            for cert in chain {
                if let spkiHash = spkiSHA256(certificate: cert),
                   Self.pinnedSPKIHashes.contains(spkiHash) {
                    return true
                }
            }
        }
        return false
    }

    private func spkiSHA256(certificate: SecCertificate) -> String? {
        guard let publicKey = SecCertificateCopyKey(certificate) else { return nil }
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else {
            return nil
        }
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        keyData.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(buffer.count), &hash)
        }
        return Data(hash).base64EncodedString()
    }
}
