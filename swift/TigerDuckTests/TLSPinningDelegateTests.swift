import Foundation
import Testing
@testable import TigerDuck

struct TLSPinningDelegateTests {
    /// Time to rotate the pins in both apps and ship the builds before a set lapses and the
    /// installed apps fall back to system trust.
    static let rotationLeadTime: TimeInterval = 45 * 24 * 60 * 60

    @Test("No pin set is within 45 days of its expiration")
    func pinSetsOutlastTheRotationLeadTime() {
        let deadline = Date().addingTimeInterval(Self.rotationLeadTime)
        #expect(!TLSPinningDelegate.pinSets.isEmpty)
        for set in TLSPinningDelegate.pinSets {
            #expect(
                set.expiration >= deadline,
                "The \(set.hostSuffix) pins expire on \(set.expiration); rotate them in both apps"
            )
        }
    }
}

#if os(iOS)
extension TLSPinningDelegateTests {
    /// The leaf and intermediate api.lib.ntust.edu.tw served on 2026-10-13 (public data).
    static let libraryChain = [
        [UInt8](Data(base64Encoded: "MIIEoTCCBEigAwIBAgIQOqkiLkqszV8f//K74ZSLZDAKBggqhkjOPQQDAjBgMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTcwNQYDVQQDEy5TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgRTM2MB4XDTI1MTAyMTAwMDAwMFoXDTI2MTEwNDIzNTk1OVowHzEdMBsGA1UEAxMUYXBpLmxpYi5udHVzdC5lZHUudHcwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAS+nMDc055O76kbTMx+iKQXWtVtwZW4XtkpsLzvQp0xvFUvkmCT2EZkGHQal/VeCvy1GBWHQPZmDGGY6TvKigJSB8CPxIW1rTR9J6+8GzCUvKRdewICsG84nXLTi+cUtmejggMGMIIDAjAfBgNVHSMEGDAWgBQXmagEwW/kLXCoChA9A9PpGrgmYzAdBgNVHQ4EFgQU+nKECd3NpLUpnm3BbZGmuMblWqwwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwSQYDVR0gBEIwQDA0BgsrBgEEAbIxAQICBzAlMCMGCCsGAQUFBwIBFhdodHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBAgEwgYQGCCsGAQUFBwEBBHgwdjBPBggrBgEFBQcwAoZDaHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljU2VydmVyQXV0aGVudGljYXRpb25DQURWRTM2LmNydDAjBggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wOQYDVR0RBDIwMIIUYXBpLmxpYi5udHVzdC5lZHUudHeCGHd3dy5hcGkubGliLm50dXN0LmVkdS50dzCCAX4GCisGAQQB1nkCBAIEggFuBIIBagFoAHYA2AlVO5RPev/IFhlvlE+Fq7D4/F6HVSYPFdEucrtFSxQAAAGaByt6rQAABAMARzBFAiEAqKg3DgbTXqDNR4CokVhOPAX4j46MfLNVqSHdFSuuf60CIHWym/n3WXhu0Yd+PwAMrxApa/Jv/cAMjAZ46DNBXhs8AHcAr2eIO1ewTt2Pptl+9i6o64EKx3Fg8CReVdYML+eFhzoAAAGaByt7EgAABAMASDBGAiEAxpud8G2Jyl4AQapectBosW3AX0x/1UuhE4HNCsGDLrYCIQC58XiMNzieWwrzC8MWbdntEDvwD8gwaVuCyxiHu3vpAAB1AKyrMHBs6+yEMfQT0vSRXxEeQiRDsfKmjE88KzunHgLDAAABmgcrek8AAAQDAEYwRAIgEFcM7ZsDLZDM31A7LSqIPSrNQBZKTuQE1Y/57xNTdRYCICc4IvViW2GqMQ2uVA2YgDiBRYJwMeEq+mbEvg8ryWg0MAoGCCqGSM49BAMCA0cAMEQCIA/V8wdTaQ/oyIpvum3tgc0nD7q/nBcu0bueky84uP+0AiBzC9YR8D9I891OcspF6bVzyjzskAekVvcHNI14fflDow==")!),
        [UInt8](Data(base64Encoded: "MIIDXzCCAuagAwIBAgIQNuBZ7YiN1Xrt1XC2cn+b2jAKBggqhkjOPQQDAzBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBFNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBgMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTcwNQYDVQQDEy5TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgRTM2MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaKGnbAUnBYljHDmn/yUhxe3TLxKYuyzc9VXoSaCEV5F73Fhfa/Si/RMsmwTFW3R9s7J6JpYZFmu4do3vk/Vgl6OCAYEwggF9MB8GA1UdIwQYMBaAFNEi2kxZ8UtfJjiqndbu6w3D+6lhMB0GA1UdDgQWBBQXmagEwW/kLXCoChA9A9PpGrgmYzAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwGwYDVR0gBBQwEjAGBgRVHSAAMAgGBmeBDAECATBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNTZXJ2ZXJBdXRoZW50aWNhdGlvblJvb3RFNDYuY3JsMIGEBggrBgEFBQcBAQR4MHYwTwYIKwYBBQUHMAKGQ2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1NlcnZlckF1dGhlbnRpY2F0aW9uUm9vdEU0Ni5wN2MwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMAoGCCqGSM49BAMDA2cAMGQCMFsKnBQDh64l+v+aUYWjDCJKQMxHUUGmcwAYDIjJ9pbRYItMCIx5xu0oUb6sIfTXqQIwPddcsDE4KdeLu1hJdpHgdLvsHAK3vygyLGujMU9xBJCDackRT93VHEE0gppgNqdV")!),
    ]

    @Test("Every pin is the SPKI hash, as the app computes it, of a certificate NTUST serves")
    func pinsMatchTheServedChains() {
        let served = Set((MailTLSVerifierTests.chain + Self.libraryChain).compactMap { der in
            SecCertificateCreateWithData(nil, Data(der) as CFData)
                .flatMap(TLSPinningDelegate.sha256SPKIBase64(of:))
        })
        for set in TLSPinningDelegate.pinSets {
            #expect(set.pins.isSubset(of: served), "\(set.hostSuffix): \(set.pins.subtracting(served))")
        }
    }
}
#endif
