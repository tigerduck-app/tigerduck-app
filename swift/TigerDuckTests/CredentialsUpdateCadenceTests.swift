import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct CredentialsUpdateCadenceTests {
    @Test("a new or changed token goes at once, an unchanged one only after an hour")
    func cadence() {
        let now = Date()
        #expect(PushCoordinator.credentialsUpdateIsDue(accepted: nil, fingerprint: 1, now: now))
        #expect(PushCoordinator.credentialsUpdateIsDue(accepted: (2, now - 60), fingerprint: 1, now: now))
        #expect(!PushCoordinator.credentialsUpdateIsDue(accepted: (1, now - 60), fingerprint: 1, now: now))
        #expect(PushCoordinator.credentialsUpdateIsDue(accepted: (1, now - 3600), fingerprint: 1, now: now))
    }
}
