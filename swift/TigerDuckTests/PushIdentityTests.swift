import Foundation
import Testing
@testable import TigerDuck

struct PushIdentityTests {

    @Test func loadOrCreate_producesWellFormedUUID() {
        // The minted id must be a parseable UUID. v3 collapsed the former
        // userId/deviceId pair into a single `uuid`. The Keychain persistence
        // path itself is tested at the integration level — Valet silently
        // no-ops in xctest host processes without Keychain entitlement, which
        // would produce false-negative stability assertions here.
        let identity = PushIdentity.loadOrCreate()

        #expect(!identity.uuid.isEmpty)

        // loadOrCreate mints a lowercased UUID string, so match case-insensitively.
        let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        #expect(identity.uuid.range(of: uuidPattern, options: .regularExpression) != nil)
    }
}
