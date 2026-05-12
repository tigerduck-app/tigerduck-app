import XCTest
@testable import TigerDuck

final class WatchSyncCoordinatorTests: XCTestCase {

    final class StubSession: WatchSessionPushing {
        var pushedContexts: [[String: Any]] = []
        var isPaired = true
        var isWatchAppInstalled = true
        func updateApplicationContext(_ context: [String: Any]) throws {
            pushedContexts.append(context)
        }
    }

    @MainActor
    func test_push_encodesAndForwards() async throws {
        let session = StubSession()
        let coord = WatchSyncCoordinator(session: session)
        coord.push(
            courses: [],
            accentHex: "#FF8800",
            loggedIn: true,
            languageTag: "zh-Hant-TW"
        )
        // Coordinator pushes synchronously when called directly.
        XCTAssertEqual(session.pushedContexts.count, 1)
        let dict = session.pushedContexts[0]
        XCTAssertEqual(dict[WatchWireFormat.Key.accentHex] as? String, "#FF8800")
        XCTAssertEqual(dict[WatchWireFormat.Key.loggedIn] as? Bool, true)
    }

    @MainActor
    func test_push_skipsWhenWatchNotInstalled() {
        let session = StubSession()
        session.isWatchAppInstalled = false
        let coord = WatchSyncCoordinator(session: session)
        coord.push(courses: [], accentHex: "#000", loggedIn: false, languageTag: nil)
        XCTAssertTrue(session.pushedContexts.isEmpty)
    }

    @MainActor
    func test_debounce_coalescesBurstWithin500ms() async throws {
        let session = StubSession()
        let coord = WatchSyncCoordinator(session: session)
        coord.scheduleDebouncedPush(courses: [], accentHex: "#A", loggedIn: true, languageTag: nil)
        coord.scheduleDebouncedPush(courses: [], accentHex: "#B", loggedIn: true, languageTag: nil)
        coord.scheduleDebouncedPush(courses: [], accentHex: "#C", loggedIn: true, languageTag: nil)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(session.pushedContexts.count, 1)
        XCTAssertEqual(session.pushedContexts[0][WatchWireFormat.Key.accentHex] as? String, "#C")
    }
}
