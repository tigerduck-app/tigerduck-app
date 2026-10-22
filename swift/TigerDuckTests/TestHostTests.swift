import Testing
@testable import TigerDuck

@MainActor
struct TestHostTests {

    @Test func testHostBuildsNoAppState() {
        #expect(CloudSyncCoordinator.shared == nil)
    }
}
