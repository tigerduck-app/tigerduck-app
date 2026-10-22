import Foundation
import Testing
@testable import TigerDuck

struct PushIdentityTests {

    @Test func loadOrCreate_producesWellFormedUUID() {
        let identity = PushIdentity.loadOrCreate()

        #expect(!identity.uuid.isEmpty)

        let uuidPattern = #"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"#
        #expect(identity.uuid.range(of: uuidPattern, options: .regularExpression) != nil)
    }
}
