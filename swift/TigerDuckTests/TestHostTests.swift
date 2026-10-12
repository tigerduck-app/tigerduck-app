import Testing
@testable import TigerDuck

@MainActor
struct TestHostTests {

    /// `AppState.init` is where the launch work starts: migrations, push registration, and on
    /// the first appearance a school sync. The test host runs an empty scene and never builds it.
    @Test func testHostBuildsNoAppState() {
        #expect(CloudSyncCoordinator.shared == nil)
    }
}
