import Foundation
import Testing
@testable import TigerDuck

struct PushIdentityTests {

    @Test func loadOrCreate_producesDistinctWellFormedUUIDs() {
        // Minted ids must be parseable UUIDs. The Keychain persistence path
        // itself is tested at the integration level — Valet silently no-ops
        // in xctest host processes without Keychain entitlement, which
        // would produce false-negative stability assertions here.
        let identity = PushIdentity.loadOrCreate()

        #expect(!identity.userId.isEmpty)
        #expect(!identity.deviceId.isEmpty)
        #expect(identity.userId != identity.deviceId)

        let uuidPattern = #"^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#
        #expect(identity.userId.range(of: uuidPattern, options: .regularExpression) != nil)
        #expect(identity.deviceId.range(of: uuidPattern, options: .regularExpression) != nil)
    }
}
