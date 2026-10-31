import Testing
@testable import TigerDuck

@MainActor
struct TestHostTests {

    @Test func testHostBuildsNoAppEnvironment() {
        #expect(CloudSyncCoordinator.shared == nil)
    }
}
