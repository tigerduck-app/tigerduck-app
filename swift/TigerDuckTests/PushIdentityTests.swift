import Foundation
import Testing
@testable import TigerDuck

struct PushIdentityTests {

    @Test func loadOrCreate_producesWellFormedUUID() {
        // The minted id must be a parseable UUID. Keychain persistence is tested at integration
        // level: Valet silently no-ops in xctest hosts without the Keychain entitlement, which
        // would give false-negative stability assertions here.
        let identity = PushIdentity.loadOrCreate()

        #expect(!identity.uuid.isEmpty)

        // loadOrCreate mints a lowercased UUID string, so match case-insensitively.
        let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        #expect(identity.uuid.range(of: uuidPattern, options: .regularExpression) != nil)
    }
}
