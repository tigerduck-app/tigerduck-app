import Foundation
import Security
import Testing
@testable import TigerDuck

struct TLSSPKITests {
    typealias F = TLSPinFixtures

    @Test("An RSA 3072 key, as Sectigo's R36 intermediates have, hashes as openssl hashes its SPKI")
    func rsa3072MatchesOpenSSL() {
        #expect(TLSSPKI.sha256Base64(ofDER: F.rsa3072DER) == F.rsa3072SPKI)
    }

    @Test("A key of a kind it does not know gives no hash")
    func anUnknownKeyGivesNone() {
        #expect(TLSSPKI.sha256Base64(ofDER: F.p521DER) == nil)
    }
}
