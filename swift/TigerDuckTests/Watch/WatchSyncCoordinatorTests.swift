import Testing
import UIKit
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
            coord.scheduleDebouncedPush(.init(courses: [], customNames: [:], accentHex: accent,
                                              loggedIn: true, languageTag: nil, visualPreset: .default))
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

    @MainActor
    private final class Counter {
        var count = 0
    }

    @MainActor
    private final class Flag {
        var value = false
    }

    /// iOS can launch the app in the background for a Watch message, with no scene and so no
    /// `WatchSyncBridge`, so the coordinator answers from the source installed at launch.
    @MainActor
    func test_syncRequest_isAnsweredFromThePayloadSource() async throws {
        let session = StubSession()
        let timer = ManualSleeper()
        let republished = Counter()
        let coord = WatchSyncCoordinator(
            session: session,
            sleep: { await timer.sleep(for: $0) },
            republishCredentials: { republished.count += 1 }
        )
        coord.setPayloadSource {
            .init(courses: [], customNames: [:], accentHex: "#123456",
                  loggedIn: true, languageTag: nil, visualPreset: .default)
        }

        coord.session(WCSession.default, didReceiveMessage: [
            WatchWireFormat.MessageKey.kind: WatchWireFormat.MessageKind.syncRequest,
        ])
        try await timer.waitUntilArmed()
        await timer.fire()
        await coord.debounceTask?.value

        XCTAssertEqual(session.pushedContexts.count, 1)
        XCTAssertEqual(session.pushedContexts[0][WatchWireFormat.Key.accentHex] as? String, "#123456")
        XCTAssertEqual(republished.count, 1)
    }

    /// Every data change pushes, and most change nothing the Watch shows. Only the stamp would
    /// differ, so the same content is not sent twice.
    @MainActor
    func test_unchangedContent_isNotPushedAgain() {
        let session = StubSession()
        let coord = WatchSyncCoordinator(session: session)
        func push(accent: String) {
            coord.push(courses: [], customNames: [:], accentHex: accent,
                       loggedIn: true, languageTag: nil, visualPreset: .default)
        }

        push(accent: "#AAAAAA")
        push(accent: "#AAAAAA")
        XCTAssertEqual(session.pushedContexts.count, 1)

        push(accent: "#BBBBBB")
        XCTAssertEqual(session.pushedContexts.count, 2)
    }

    /// The Watch asks when it may have lost what it had, so its request is answered even when
    /// nothing changed. Credentials go out on that request and on no ordinary push.
    @MainActor
    func test_syncRequest_pushesUnchangedContentAndOnlyItResendsCredentials() async throws {
        let session = StubSession()
        let timer = ManualSleeper()
        let republished = Counter()
        let coord = WatchSyncCoordinator(
            session: session,
            sleep: { await timer.sleep(for: $0) },
            republishCredentials: { republished.count += 1 }
        )
        coord.setPayloadSource {
            .init(courses: [], customNames: [:], accentHex: "#123456",
                  loggedIn: true, languageTag: nil, visualPreset: .default)
        }

        coord.pushCurrentState()
        try await timer.waitUntilArmed(atLeast: 1)
        await timer.fire()
        await coord.debounceTask?.value
        XCTAssertEqual(session.pushedContexts.count, 1)
        XCTAssertEqual(republished.count, 0)

        coord.answerSyncRequest()
        try await timer.waitUntilArmed(atLeast: 2)
        await timer.fire()
        await coord.debounceTask?.value
        XCTAssertEqual(session.pushedContexts.count, 2)
        XCTAssertEqual(republished.count, 1)
    }

    /// A Watch message can launch the app behind the lock screen, where the library password
    /// cannot be read; the Watch does not ask again, so the credentials follow the unlock.
    @MainActor
    func test_syncRequestWhileLocked_sendsTheCredentialsAfterTheUnlock() {
        let center = NotificationCenter()
        let unlocked = Flag()
        let republished = Counter()
        let coord = WatchSyncCoordinator(
            session: StubSession(),
            sleep: { _ in },
            republishCredentials: { republished.count += 1 },
            isProtectedDataAvailable: { unlocked.value },
            notificationCenter: center
        )

        coord.answerSyncRequest()
        XCTAssertEqual(republished.count, 0)

        unlocked.value = true
        center.post(name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        XCTAssertEqual(republished.count, 1)

        // Owed once: a later return to the app sends nothing more.
        center.post(name: UIApplication.didBecomeActiveNotification, object: nil)
        XCTAssertEqual(republished.count, 1)
        withExtendedLifetime(coord) {}
    }
}
