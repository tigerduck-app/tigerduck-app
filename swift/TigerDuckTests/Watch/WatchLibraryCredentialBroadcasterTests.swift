import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct WatchLibraryCredentialBroadcasterTests {
    private static func broadcaster() throws -> WatchLibraryCredentialBroadcaster {
        let defaults = try #require(UserDefaults(suiteName: "WatchLibraryCredentialBroadcasterTests-\(UUID().uuidString)"))
        return WatchLibraryCredentialBroadcaster(session: WatchSyncCoordinatorTests.StubSession(), defaults: defaults)
    }

    @Test("the demo's library credential goes to the watch with the demo's code, which the watch shows unasked")
    func theDemoCredentialCarriesItsCode() throws {
        let fixture = try #require(DemoFixture.bundled)
        let code = try #require(fixture.libraryQr?.content)

        let payload = try Self.broadcaster().credential(
            username: fixture.normalizedStudentId, password: fixture.libraryPassword, epoch: 1
        )

        #expect(payload?.username == fixture.normalizedStudentId)
        #expect(payload?.code == code)
    }

    @Test("a library credential of a real reader goes without a code")
    func aRealCredentialCarriesNone() throws {
        let payload = try Self.broadcaster().credential(username: "B11000000", password: "not-the-demo", epoch: 1)

        #expect(payload?.username == "B11000000")
        #expect(payload?.code == nil)
    }
}
