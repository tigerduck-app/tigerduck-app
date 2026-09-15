#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct MailTLSVerifierTests {
    /// The *.ntust.edu.tw leaf and TWCA intermediate served on mail.ntust.edu.tw:993
    /// (public data, captured 2026-09-15).
    static let leafDER = [UInt8](Data(base64Encoded: "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")!)
    static let intermediateDER = [UInt8](Data(base64Encoded: "MIIFxjCCA66gAwIBAgIQQAE0s2gAAAAAAAAM0KoI7DANBgkqhkiG9w0BAQsFADBRMQswCQYDVQQGEwJUVzESMBAGA1UEChMJVEFJV0FOLUNBMRAwDgYDVQQLEwdSb290IENBMRwwGgYDVQQDExNUV0NBIEdsb2JhbCBSb290IENBMB4XDTIzMTAxNjA5MDEwNFoXDTMwMTAxNjE1NTk1OVowUzELMAkGA1UEBhMCVFcxEjAQBgNVBAoTCVRBSVdBTi1DQTEwMC4GA1UEAxMnVFdDQSBTZWN1cmUgU1NMIENlcnRpZmljYXRpb24gQXV0aG9yaXR5MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAyS5amjYQhd10hZs00r7RXdI3ASka2AQmJnOyA6bqvAYOMlMECUdlsjDccdmMdHx8YTYYMtmCy+UBRJZ/ytVANVQlfcUvXzWfauFs8XpCC/Th+Ed2tIEEGK218QsBebImAHPGDvp2YgljXVaQR/0FeN1lIzQ3iUkad0dCsC/bxFiWsmsjeSscTaxrYzHFADUhK0qj4W5PmOuwlAR3C4XXgzPAI3V0qBpQ7sqgNLaNBFTZkP6AVryZC+DapfWBIMmIxIOg8g25MKb4XvXkCLYKIxi8Djhv1zSmLLrKbQFZrjWlD/OWqInPPmSwBrKZ13EMQhoRRi1pXfN+J2ugR/PUQQIDAQABo4IBljCCAZIwHwYDVR0jBBgwFoAUSNvN3o7pSXJaiOix2D0Hs7lrZlAwHQYDVR0OBBYEFJLn+mIWcYzzl3FCxgan4EZhS1y2MA4GA1UdDwEB/wQEAwIBhjAdBgNVHSUEFjAUBggrBgEFBQcDAQYIKwYBBQUHAwIwSgYDVR0gBEMwQTA1BgsrBgEEAYK/JQEBFTAmMCQGCCsGAQUFBwIBFhhodHRwczovL3d3dy50d2NhLmNvbS50dy8wCAYGZ4EMAQICMEkGA1UdHwRCMEAwPqA8oDqGOGh0dHA6Ly9yb290Y2EudHdjYS5jb20udHcvVFdDQVJDQS9nbG9iYWxfcmV2b2tlXzQwOTYuY3JsMBIGA1UdEwEB/wQIMAYBAf8CAQAwdgYIKwYBBQUHAQEEajBoMDwGCCsGAQUFBzAChjBodHRwOi8vc3Nsc2VydmVyLnR3Y2EuY29tLnR3L2NhY2VydC9yb290NDA5Ni5jcnQwKAYIKwYBBQUHMAGGHGh0dHA6Ly9yb290b2NzcC50d2NhLmNvbS50dy8wDQYJKoZIhvcNAQELBQADggIBADVzQW2rRsMiWoVrBdZX1BiOgN6B/Ryt2zpq8uRxFQspvGYfUVIm4uU4AaPR7aQ5KwpKjDWv2ncvX2ssCY54B82g2mxEEVEdu5PFl0jkuk4LmPsClYZc6J6odUbVI3wtv2yF6+fqQrO+gDhEIhlg3IqWICfiyJZS+p2TirMszGzs4a+K9tZXrS2W/jKsSt4bSmcIzDpwm2gSaSuLDIAwq0WrD29kA7+N+rMMs4zBIVKyYm9r08q4UOGU16J7mKBrF0KYDZFyT9Hq5HAX2uwYoQJxQ5Z0BR8eZH8AIIi2vsFC8pkv2ra12dldd3Pivm0mdratbn1Z6MQ71FKR9Ui3L8P+0xu8DkhhxE11Ogpl+aquBUqGcvlD0SgpXy+eoeFaRhFXRUkWtH/3XYo+h+N+4jZmgjCLd4+YI+u5tbUGpyBMABmUDiqZxcrPGc4cvXExqYePUg6cFCDcjqGCxqSu5BPbA5R+DSTkn5Sc1WQzORJpD5b7pcEq8msolev88dcmddLXMyWzXQfPHA4vaQD74lr5LIzn6BRjVv+ZB7Y0ZTnnOimDXxn7Cxqd+1/8ldRis/tO/JWZsMm5ruvCppwCZUdXjSNI5R1OxzVwTVLzsCoiSYPV0agda5dQ9wayB6OohBK7+ZU2V3sZwE2xwHdDzfhbdzmI++TxtOurDHbkfkED")!)
    static let chain = [leafDER, intermediateDER]
    /// Inside the leaf's validity and before the pin set's 2027-01-18 expiry.
    static let pinnedDate = ISO8601DateFormatter().date(from: "2026-09-16T00:00:00Z")!
    /// After the pin set expired but while the leaf is still valid.
    static let expiredPinDate = ISO8601DateFormatter().date(from: "2027-01-20T00:00:00Z")!
    static let appPins: Set<String> = [
        "Nz3wUtBXZ+2HPXuSyx4enXs62i/PH4MKtayV9N4X0PE=",
        "9VZ7Yd685RTXsE6rL/puuMbnejYaXwaZasGL7c+Uolc=",
    ]

    @Test func mailHostUsesTheAppPins() {
        #expect(TLSPinningDelegate.pinPolicy(forHost: "mail.ntust.edu.tw", now: Self.pinnedDate)
            == .pinned(Self.appPins))
    }

    @Test func pinsGoInertAfterTheirExpiry() {
        #expect(TLSPinningDelegate.pinPolicy(forHost: "mail.ntust.edu.tw", now: Self.expiredPinDate)
            == .expired)
    }

    @Test func unrelatedHostsAreNotPinned() {
        #expect(TLSPinningDelegate.pinPolicy(forHost: "example.com", now: Self.pinnedDate) == .notPinned)
    }

    @Test func theRealChainPassesForTheMailHost() {
        #expect(MailTLSVerifier.verify(derChain: Self.chain, host: "mail.ntust.edu.tw", now: Self.pinnedDate))
    }

    @Test func aHostTheCertificateDoesNotNameFails() {
        #expect(!MailTLSVerifier.verify(derChain: Self.chain, host: "example.com", now: Self.pinnedDate))
    }

    @Test func aValidChainWithoutAMatchingPinFails() {
        #expect(!MailTLSVerifier.verify(
            derChain: Self.chain, host: "mail.ntust.edu.tw", now: Self.pinnedDate,
            pinPolicy: .pinned(["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="])
        ))
    }

    @Test func expiredPinsFallBackToSystemTrust() {
        #expect(MailTLSVerifier.verify(
            derChain: Self.chain, host: "mail.ntust.edu.tw", now: Self.expiredPinDate
        ))
    }

    @Test func bytesThatAreNotACertificateFail() {
        #expect(!MailTLSVerifier.verify(derChain: [[1, 2, 3]], host: "mail.ntust.edu.tw", now: Self.pinnedDate))
        #expect(!MailTLSVerifier.verify(derChain: [], host: "mail.ntust.edu.tw", now: Self.pinnedDate))
    }

    @Test func releaseBuildsHideTheFeatureUntilConsent() {
        #expect(SchoolMailAvailability.releaseEnabled == false)
        #expect(SchoolMailAvailability.isEnabled)  // tests run DEBUG builds
    }

    @Test func addressesAreLowercase() {
        #expect(MailConstants.address(forStudentID: " B10000000 ") == "b10000000@mail.ntust.edu.tw")
    }
}
#endif
