import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CredentialsUpdateCadenceTests {
    @Test("a new or changed token goes at once, an unchanged one only after an hour")
    func cadence() {
        let now = Date()
        let hourly = SendLedger.Resend.after(3600)
        #expect(SendLedger.isDue(accepted: nil, fingerprint: "a", resend: hourly, now: now))
        #expect(SendLedger.isDue(accepted: ("b", now - 60), fingerprint: "a", resend: hourly, now: now))
        #expect(!SendLedger.isDue(accepted: ("a", now - 60), fingerprint: "a", resend: hourly, now: now))
        #expect(SendLedger.isDue(accepted: ("a", now - 3600), fingerprint: "a", resend: hourly, now: now))
    }
}
