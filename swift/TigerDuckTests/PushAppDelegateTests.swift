#if os(iOS)
import Foundation
import Testing
import UIKit
import os
@testable import TigerDuck

/// The backend's `sync_trigger` push wakes the app in the background, where iOS waits a limited
/// time for the completion handler (https://github.com/tigerduck-app/tigerduck-app/issues/449).
@MainActor
struct PushAppDelegateTests {
    /// What a completion handler was called with, from any thread, and when.
    private final class Answers: Sendable {
        private let state = OSAllocatedUnfairLock<[(result: UIBackgroundFetchResult, at: Date)]>(initialState: [])

        var results: [UIBackgroundFetchResult] { state.withLock { $0.map(\.result) } }
        var firstAt: Date? { state.withLock { $0.first?.at } }

        func record(_ result: UIBackgroundFetchResult) {
            state.withLock { $0.append((result, Date())) }
        }
    }

    /// Holds the calling thread, as a long synchronous stretch of a sync holds the main actor.
    private static func hold(for seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    @Test("The app declares the Remote notifications background mode, so a sync trigger reaches it in the background")
    func theAppDeclaresRemoteNotifications() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes?.contains("remote-notification") == true)
    }

    @Test("A sync trigger is answered with what its sync came to",
          arguments: [(FullSyncOutcome.synced, UIBackgroundFetchResult.newData), (.skipped, .noData), (.failed, .failed)])
    func aSyncTriggerIsAnsweredWithItsOutcome(outcome: FullSyncOutcome, expected: UIBackgroundFetchResult) async {
        let delegate = PushAppDelegate()
        delegate.onSyncTrigger = { outcome }

        let result = await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "sync_trigger"]) {
                continuation.resume(returning: $0)
            }
        }

        #expect(result == expected)
    }

    @Test("A sync that outlasts the limit is cancelled and answered failed at the limit, and not again when it ends")
    func aSyncPastTheLimitIsCancelledAndAnsweredOnce() async {
        let answers = Answers()
        var sawCancellation = false
        var ended = false

        PushAppDelegate.run({
            try? await Task.sleep(for: .seconds(10))
            sawCancellation = Task.isCancelled
            ended = true
            return .newData
        }, within: .milliseconds(20), then: answers.record)
        while !ended { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(sawCancellation)
        #expect(answers.results == [.failed])
    }

    @Test("The limit answers while the sync holds the main actor")
    func theLimitAnswersWhileTheMainActorIsBusy() async throws {
        let answers = Answers()
        var busyUntil: Date?

        PushAppDelegate.run({
            Self.hold(for: 0.3)
            busyUntil = Date()
            return .newData
        }, within: .milliseconds(20), then: answers.record)
        while busyUntil == nil { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(answers.results == [.failed])
        #expect(try #require(answers.firstAt) < #require(busyUntil))
    }

    @Test("Another push, or a sync trigger before a sync is bound, is answered at once with no data")
    func otherPushesAreAnsweredWithNoData() {
        let delegate = PushAppDelegate()
        var results: [UIBackgroundFetchResult] = []

        delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "sync_trigger"]) {
            results.append($0)
        }
        delegate.onSyncTrigger = {
            Issue.record("a push that is no sync trigger ran a sync")
            return .synced
        }
        delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "bulletin"]) {
            results.append($0)
        }

        #expect(results == [.noData, .noData])
    }
}
#endif
