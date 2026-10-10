import Testing
import WatchConnectivity
import XCTest
@testable import TigerDuck

final class WatchSyncCoordinatorTests: XCTestCase {

    final class StubSession: WatchSessionPushing {
        var pushedContexts: [[String: Any]] = []
        var isPaired = true
        var isWatchAppInstalled = true
        var isReachable = true
        func updateApplicationContext(_ context: [String: Any]) throws {
            pushedContexts.append(context)
        }
        // These tests cover only the application-context path. The message and user-info members
        // satisfy the protocol and are never called; `WCSessionUserInfoTransfer` has no
        // constructible stub value.
        func transferUserInfo(_ userInfo: [String: Any]) -> WCSessionUserInfoTransfer {
            fatalError("transferUserInfo is not exercised by WatchSyncCoordinatorTests")
        }
        func sendMessage(_ message: [String: Any],
                         replyHandler: (([String: Any]) -> Void)?,
                         errorHandler: ((Error) -> Void)?) {}
    }

    @MainActor
    func test_push_encodesAndForwards() async throws {
        let session = StubSession()
        let coord = WatchSyncCoordinator(session: session)
        coord.push(
            courses: [],
            customNames: [:],
            accentHex: "#FF8800",
            loggedIn: true,
            languageTag: "zh-Hant-TW",
            visualPreset: .iosInspired
        )
        // Coordinator pushes synchronously when called directly.
        XCTAssertEqual(session.pushedContexts.count, 1)
        let dict = session.pushedContexts[0]
        XCTAssertEqual(dict[WatchWireFormat.Key.accentHex] as? String, "#FF8800")
        XCTAssertEqual(dict[WatchWireFormat.Key.loggedIn] as? Bool, true)
        XCTAssertEqual(
            dict[WatchWireFormat.Key.visualPreset] as? String,
            VisualPreset.iosInspired.rawValue
        )
    }

    @MainActor
    func test_push_skipsWhenWatchNotInstalled() {
        let session = StubSession()
        session.isWatchAppInstalled = false
        let coord = WatchSyncCoordinator(session: session)
        coord.push(courses: [], customNames: [:], accentHex: "#000",
                   loggedIn: false, languageTag: nil, visualPreset: .default)
        XCTAssertTrue(session.pushedContexts.isEmpty)
    }

    @MainActor
    func test_debounce_coalescesBurstWithin500ms() async throws {
        let session = StubSession()
        let timer = ManualSleeper()
        let coord = WatchSyncCoordinator(session: session, sleep: { await timer.sleep(for: $0) })
        var windows: [Task<Void, Never>] = []
        for accent in ["#A", "#B", "#C"] {
            coord.scheduleDebouncedPush(courses: [], customNames: [:], accentHex: accent,
                                        loggedIn: true, languageTag: nil, visualPreset: .default)
            windows.append(try XCTUnwrap(coord.debounceTask))
        }
        try await timer.waitUntilArmed(atLeast: 3)
        let durations = await timer.requestedDurations
        XCTAssertEqual(durations, [Duration](repeating: .milliseconds(500), count: 3))
        XCTAssertTrue(session.pushedContexts.isEmpty)
        // Each schedule cancelled the wait before it; firing ends the last. Counting once every
        // wait has finished leaves no late push unseen.
        await timer.fire()
        for window in windows { await window.value }
        XCTAssertEqual(session.pushedContexts.count, 1)
        XCTAssertEqual(session.pushedContexts[0][WatchWireFormat.Key.accentHex] as? String, "#C")
    }
}
