import CryptoKit
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
    /// The chain api.lib.ntust.edu.tw served on 2026-10-13 (public data): its leaf, Sectigo DV
    /// E36, and Sectigo Public Server Authentication Root E46 cross-signed by USERTrust ECC.
    static let libraryChain = [
        [UInt8](Data(base64Encoded: "MIIEoTCCBEigAwIBAgIQOqkiLkqszV8f//K74ZSLZDAKBggqhkjOPQQDAjBgMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTcwNQYDVQQDEy5TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgRTM2MB4XDTI1MTAyMTAwMDAwMFoXDTI2MTEwNDIzNTk1OVowHzEdMBsGA1UEAxMUYXBpLmxpYi5udHVzdC5lZHUudHcwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAS+nMDc055O76kbTMx+iKQXWtVtwZW4XtkpsLzvQp0xvFUvkmCT2EZkGHQal/VeCvy1GBWHQPZmDGGY6TvKigJSB8CPxIW1rTR9J6+8GzCUvKRdewICsG84nXLTi+cUtmejggMGMIIDAjAfBgNVHSMEGDAWgBQXmagEwW/kLXCoChA9A9PpGrgmYzAdBgNVHQ4EFgQU+nKECd3NpLUpnm3BbZGmuMblWqwwDgYDVR0PAQH/BAQDAgeAMAwGA1UdEwEB/wQCMAAwEwYDVR0lBAwwCgYIKwYBBQUHAwEwSQYDVR0gBEIwQDA0BgsrBgEEAbIxAQICBzAlMCMGCCsGAQUFBwIBFhdodHRwczovL3NlY3RpZ28uY29tL0NQUzAIBgZngQwBAgEwgYQGCCsGAQUFBwEBBHgwdjBPBggrBgEFBQcwAoZDaHR0cDovL2NydC5zZWN0aWdvLmNvbS9TZWN0aWdvUHVibGljU2VydmVyQXV0aGVudGljYXRpb25DQURWRTM2LmNydDAjBggrBgEFBQcwAYYXaHR0cDovL29jc3Auc2VjdGlnby5jb20wOQYDVR0RBDIwMIIUYXBpLmxpYi5udHVzdC5lZHUudHeCGHd3dy5hcGkubGliLm50dXN0LmVkdS50dzCCAX4GCisGAQQB1nkCBAIEggFuBIIBagFoAHYA2AlVO5RPev/IFhlvlE+Fq7D4/F6HVSYPFdEucrtFSxQAAAGaByt6rQAABAMARzBFAiEAqKg3DgbTXqDNR4CokVhOPAX4j46MfLNVqSHdFSuuf60CIHWym/n3WXhu0Yd+PwAMrxApa/Jv/cAMjAZ46DNBXhs8AHcAr2eIO1ewTt2Pptl+9i6o64EKx3Fg8CReVdYML+eFhzoAAAGaByt7EgAABAMASDBGAiEAxpud8G2Jyl4AQapectBosW3AX0x/1UuhE4HNCsGDLrYCIQC58XiMNzieWwrzC8MWbdntEDvwD8gwaVuCyxiHu3vpAAB1AKyrMHBs6+yEMfQT0vSRXxEeQiRDsfKmjE88KzunHgLDAAABmgcrek8AAAQDAEYwRAIgEFcM7ZsDLZDM31A7LSqIPSrNQBZKTuQE1Y/57xNTdRYCICc4IvViW2GqMQ2uVA2YgDiBRYJwMeEq+mbEvg8ryWg0MAoGCCqGSM49BAMCA0cAMEQCIA/V8wdTaQ/oyIpvum3tgc0nD7q/nBcu0bueky84uP+0AiBzC9YR8D9I891OcspF6bVzyjzskAekVvcHNI14fflDow==")!),
        [UInt8](Data(base64Encoded: "MIIDXzCCAuagAwIBAgIQNuBZ7YiN1Xrt1XC2cn+b2jAKBggqhkjOPQQDAzBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBFNDYwHhcNMjEwMzIyMDAwMDAwWhcNMzYwMzIxMjM1OTU5WjBgMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTcwNQYDVQQDEy5TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gQ0EgRFYgRTM2MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEaKGnbAUnBYljHDmn/yUhxe3TLxKYuyzc9VXoSaCEV5F73Fhfa/Si/RMsmwTFW3R9s7J6JpYZFmu4do3vk/Vgl6OCAYEwggF9MB8GA1UdIwQYMBaAFNEi2kxZ8UtfJjiqndbu6w3D+6lhMB0GA1UdDgQWBBQXmagEwW/kLXCoChA9A9PpGrgmYzAOBgNVHQ8BAf8EBAMCAYYwEgYDVR0TAQH/BAgwBgEB/wIBADAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwGwYDVR0gBBQwEjAGBgRVHSAAMAgGBmeBDAECATBUBgNVHR8ETTBLMEmgR6BFhkNodHRwOi8vY3JsLnNlY3RpZ28uY29tL1NlY3RpZ29QdWJsaWNTZXJ2ZXJBdXRoZW50aWNhdGlvblJvb3RFNDYuY3JsMIGEBggrBgEFBQcBAQR4MHYwTwYIKwYBBQUHMAKGQ2h0dHA6Ly9jcnQuc2VjdGlnby5jb20vU2VjdGlnb1B1YmxpY1NlcnZlckF1dGhlbnRpY2F0aW9uUm9vdEU0Ni5wN2MwIwYIKwYBBQUHMAGGF2h0dHA6Ly9vY3NwLnNlY3RpZ28uY29tMAoGCCqGSM49BAMDA2cAMGQCMFsKnBQDh64l+v+aUYWjDCJKQMxHUUGmcwAYDIjJ9pbRYItMCIx5xu0oUb6sIfTXqQIwPddcsDE4KdeLu1hJdpHgdLvsHAK3vygyLGujMU9xBJCDackRT93VHEE0gppgNqdV")!),
        [UInt8](Data(base64Encoded: "MIIDRjCCAsugAwIBAgIQGp6v7G3o4ZtcGTFBto2Q3TAKBggqhkjOPQQDAzCBiDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCk5ldyBKZXJzZXkxFDASBgNVBAcTC0plcnNleSBDaXR5MR4wHAYDVQQKExVUaGUgVVNFUlRSVVNUIE5ldHdvcmsxLjAsBgNVBAMTJVVTRVJUcnVzdCBFQ0MgQ2VydGlmaWNhdGlvbiBBdXRob3JpdHkwHhcNMjEwMzIyMDAwMDAwWhcNMzgwMTE4MjM1OTU5WjBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBFNDYwdjAQBgcqhkjOPQIBBgUrgQQAIgNiAAR2+pmpbiDt+dd34wc7qNs9Xzjoq1WmVk/WSOrsfy2qw7LFeeyZYX8QeccCWvkEN/U0NSt3zn8gj1KjAIns1aeibVvjS5KToID1AZTc8GgHHs3u/iVStSBDHBv+6xnOQ6OjggEgMIIBHDAfBgNVHSMEGDAWgBQ64QmG1M8ZwpZ2dEl23OA1xmNjmjAdBgNVHQ4EFgQU0SLaTFnxS18mOKqd1u7rDcP7qWEwDgYDVR0PAQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHQYDVR0lBBYwFAYIKwYBBQUHAwEGCCsGAQUFBwMCMBEGA1UdIAQKMAgwBgYEVR0gADBQBgNVHR8ESTBHMEWgQ6BBhj9odHRwOi8vY3JsLnVzZXJ0cnVzdC5jb20vVVNFUlRydXN0RUNDQ2VydGlmaWNhdGlvbkF1dGhvcml0eS5jcmwwNQYIKwYBBQUHAQEEKTAnMCUGCCsGAQUFBzABhhlodHRwOi8vb2NzcC51c2VydHJ1c3QuY29tMAoGCCqGSM49BAMDA2kAMGYCMQCMCyBit99vX2ba6xEkDe+YO7vC0twjbkv9PKpqGGuZ61JZryjFsp+DFpEclCVy4noCMQCwvZDXD/m2Ko1HA5Bkmz7YQOFAiNDD49IWa2wdT7R3DtODaSXH/BiXv8fwB9su4tU=")!),
    ]

    /// The chain cardsystem.ntust.edu.tw served on 2026-10-13 (public data): its leaf, TWCA SSL
    /// Certification Authority, and TWCA CYBER Root CA cross-signed by TWCA Global Root CA.
    static let cyberChain = [
        [UInt8](Data(base64Encoded: "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")!),
        [UInt8](Data(base64Encoded: "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")!),
        [UInt8](Data(base64Encoded: "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")!),
    ]
    static let capturedDate = ISO8601DateFormatter().date(from: "2026-10-13T00:00:00Z")!

    /// Sectigo Public Server Authentication Root R46 (public data, from the system trust store). No
    /// pinned host serves it yet; the library's next certificate may come from it.
    static let sectigoRootR46 = [UInt8](Data(base64Encoded: "MIIFijCCA3KgAwIBAgIQdY39i658BwD6qSWn4cetFDANBgkqhkiG9w0BAQwFADBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwHhcNMjEwMzIyMDAwMDAwWhcNNDYwMzIxMjM1OTU5WjBfMQswCQYDVQQGEwJHQjEYMBYGA1UEChMPU2VjdGlnbyBMaW1pdGVkMTYwNAYDVQQDEy1TZWN0aWdvIFB1YmxpYyBTZXJ2ZXIgQXV0aGVudGljYXRpb24gUm9vdCBSNDYwggIiMA0GCSqGSIb3DQEBAQUAA4ICDwAwggIKAoICAQCTvtU2UnXYASOgHEdCSe5jtrch/cSV1UgrJnwUUxDaef0rty2k1Cz66jLdScK5vQ9IPXtamFSvnl0xdE8H/FAh3aTPaE8bEmNtJZlMKpnzSDBh+oF8HqcIStw+KxwfGExxqjWMrfhu6DtK2eWUAtaJhBOqbchPM8xQljeSM9xfiOefVNlI8JhD1mb9nxc4Q8UBUQvX4yMPFF1bFOdLvt30yNoDN9HWOaEhUTCDsG3XME6WW5HwcCSrv0WBZEMNvSE6Lzzpng3LILVCJ8zab5vuZDCQOc2TZYEhMbUjUDM3IuM47fgxMMxF/mL50V0yeUKH32rMVhlATc6qu/m1dkmU8Sf4kaWD5QazYw6A3OASVYCmO2a0OYctyPDQ0RTp5A1NDvZdV3LFOxxHVp3i1fuBYYzMTYCQNFu31xR13NgESJ/AwSiItOkcyqex8Va3e0lMWeUgFaiEAin6OJRpmkkGj80feRQXEgyDet4fsZfu+Zd4KKTIRJLpfSYFplhym3kT2BFfrsU4YjRosoYwjviQYZ4ybPUHNs2iTG7sijbt8uaZFURww3y8nDnAtOFr94MlI1fZEoDlSfB1D++N6xybVCi0ITz8fAr/73trdf+LHaAZBav6+CuBQug4urv7qv094PPK306Xlynt8xhW6aWWrL3DkJiy4Pmi1KZHQ3xtzwIDAQABo0IwQDAdBgNVHQ4EFgQUVnNYZJX5khqwEioEYnmhQBWIIUkwDgYDVR0PAQH/BAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wDQYJKoZIhvcNAQEMBQADggIBAC9cmTz8Bl6MlC5w6tIyMY208FHVvArzZJ8HXtXBc2hkeqK5Duj5XYUtqDdFqij0lgVQYKlJfp/imTYpE0RHap1VIDzYm/EDMrraQKFz6oOht0SmDpkBm+S8f74TlH7Kph52gDY9hAaLMyZlbcp+nv4fjFg4exqDsQ+8FxG75gbMY/qB8oFM2gsQa6H61SilzwZAFv97fRheORKkU55+MkIQpiGRqRxOF3yEvJ+M0ejf5lG5Nkc/kLnHvALcWxxPDkjBJYOcCj+esQMzEhonrPcibCTRAUH4WAP+JWgiH5paPHxsnnVI84HxZmduTILA7rpXDhjvLpr3Etiga+kFpaHpaPi8TD8SHkXoUsCjvxInebnMMTzD9joiFgOgyY9mpFuiTdaBJQbpdqQACj7LzTWb4OE4y2BThihCQRxEV+ioratF4yUQvNs+ZUH7G6aXD+u5dHn5HrwdVw1Hr8Mvn4dGp+smWg9WY7ViYG4A++MnESLn/pmPNPW56MORcr3Ywx65LvKRRFHQV80MNNVIIb/bE/FmJUNS0nAiNs2fxBx1IK1jcmMGDw4nztJqDby1ORrp0XZ60Vzk50lJLVU3aPAaOpg+VBeHVOmmJ1CJeyAvP/+/oYtKR5j/K3tJPsMpRmAYQqszKbrAKbkTidOIijlBO8n9pu0f9GBj39ItVQGL")!)

    /// Roots a pin set holds for a renewal, which none of its hosts serves yet.
    static let renewalRoots: [String: [[UInt8]]] = ["api.lib.ntust.edu.tw": [sectigoRootR46]]

    /// Each chain with a host that served it and a date inside its validity.
    static let servedChains: [(host: String, date: Date, chain: [[UInt8]])] = [
        ("mail.ntust.edu.tw", MailTLSVerifierTests.pinnedDate, MailTLSVerifierTests.chain),
        ("cardsystem.ntust.edu.tw", capturedDate, cyberChain),
        ("api.lib.ntust.edu.tw", capturedDate, libraryChain),
    ]

    @Test("Every pin is the SPKI hash, as the app computes it, of a certificate its own hosts serve or a renewal root")
    func pinsMatchTheirHostsChains() {
        for set in TLSPinningDelegate.pinSets {
            let certificates = Self.servedChains
                .filter { TLSPinningDelegate.pinPolicy(forHost: $0.host, now: $0.date) == .pinned(set.pins) }
                .flatMap(\.chain)
                + Self.renewalRoots[set.hostSuffix, default: []]
            let served = Set(certificates.compactMap(Self.spkiHash))
            #expect(!set.pins.isEmpty, "\(set.hostSuffix) has no pins")
            #expect(set.pins.isSubset(of: served), "\(set.hostSuffix): \(set.pins.subtracting(served))")
        }
    }

    /// Every renewal of the library's certificate since 2022 changed its key and its issuer, so the
    /// set pins both roots Sectigo issues under: E46, which the library serves cross-signed, and R46.
    @Test("The library pins both Sectigo roots")
    func libraryPinsBothSectigoRoots() {
        // The SHA-256 fingerprint Sectigo publishes, since other roots share the R46 name.
        let fingerprint = SHA256.hash(data: Data(Self.sectigoRootR46)).map { String(format: "%02X", $0) }.joined()
        #expect(fingerprint == "7BB647A62AEEAC88BF257AA522D01FFEA395E0AB45C73F93F65654EC38F25A06")
        let roots = [Self.libraryChain[2], Self.sectigoRootR46].compactMap(Self.spkiHash)
        #expect(roots.count == 2)
        let policy = TLSPinningDelegate.pinPolicy(forHost: "api.lib.ntust.edu.tw", now: Self.capturedDate)
        guard case .pinned(let pins) = policy else {
            Issue.record("api.lib.ntust.edu.tw is not pinned: \(policy)")
            return
        }
        #expect(Set(roots).isSubset(of: pins), "\(Set(roots).subtracting(pins))")
    }

    /// A renewal may serve only its leaf and intermediate, so a root pin has to match the anchor
    /// that trust evaluation adds from the system store.
    @Test("A root pin matches a chain served without its root")
    func aRootPinMatchesTheAnchorOfTheEvaluatedChain() throws {
        let leafAndIntermediate = Array(Self.libraryChain.prefix(2))
        let e46 = try #require(Self.spkiHash(Self.libraryChain[2]))
        let r46 = try #require(Self.spkiHash(Self.sectigoRootR46))
        #expect(MailTLSVerifier.verify(
            derChain: leafAndIntermediate, host: "api.lib.ntust.edu.tw", now: Self.capturedDate, pinPolicy: .pinned([e46])
        ))
        #expect(!MailTLSVerifier.verify(
            derChain: leafAndIntermediate, host: "api.lib.ntust.edu.tw", now: Self.capturedDate, pinPolicy: .pinned([r46])
        ))
    }

    static func spkiHash(_ der: [UInt8]) -> String? {
        SecCertificateCreateWithData(nil, Data(der) as CFData).flatMap(TLSPinningDelegate.sha256SPKIBase64(of:))
    }

    /// cardsystem's chain comes from TWCA's CYBER hierarchy, which NTUST's newer certificates use.
    @Test("Each captured chain passes the pins of the host that served it")
    func servedChainsPassTheirHostsPins() {
        for (host, date, chain) in Self.servedChains {
            let accepted = MailTLSVerifier.verify(derChain: chain, host: host, now: date)
            #expect(accepted, "\(host) refuses the chain it served")
        }
    }
}
#endif
