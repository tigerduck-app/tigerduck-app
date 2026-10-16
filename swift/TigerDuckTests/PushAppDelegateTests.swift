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
    /// What a completion handler was called with, from any thread.
    private final class Answers: Sendable {
        private let state = OSAllocatedUnfairLock<[UIBackgroundFetchResult]>(initialState: [])

        var results: [UIBackgroundFetchResult] { state.withLock { $0 } }

        func record(_ result: UIBackgroundFetchResult) {
            state.withLock { $0.append(result) }
        }
    }

    /// What happened, in order, from any thread.
    private final class Events: Sendable {
        private let state = OSAllocatedUnfairLock<[String]>(initialState: [])

        var all: [String] { state.withLock { $0 } }

        func record(_ event: String) {
            state.withLock { $0.append(event) }
        }
    }

    /// Holds the calling thread until `signal`, at most `seconds`, as a long synchronous stretch of
    /// a sync holds the main actor. Returns whether the signal came.
    private static func hold(until signal: DispatchSemaphore, atMost seconds: Int) -> Bool {
        signal.wait(timeout: .now() + .seconds(seconds)) == .success
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

    /// Once the push is answered iOS may suspend the app, so the widgets' reload goes out first
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/664).
    @Test("What must not wait for the next launch runs after the sync and before the answer")
    func whatMustNotWaitRunsBeforeTheAnswer() async {
        let delegate = PushAppDelegate()
        let events = Events()
        delegate.onSyncTrigger = {
            events.record("sync")
            return .synced
        }
        delegate.beforeAnsweringSyncTrigger = { events.record("widgets") }

        await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "sync_trigger"]) { _ in
                events.record("answer")
                continuation.resume()
            }
        }

        #expect(events.all == ["sync", "widgets", "answer"])
    }

    @Test("A sync that outlasts the limit is answered failed at the limit, cancelled while the app is not active, and not answered again when it ends")
    func aSyncPastTheLimitIsCancelledAndAnsweredOnce() async {
        let answers = Answers()
        var sawCancellation = false
        var ended = false

        PushAppDelegate.run({
            try? await Task.sleep(for: .seconds(10))
            sawCancellation = Task.isCancelled
            ended = true
            return .newData
        }, within: .milliseconds(20), appIsActive: { false }, then: answers.record)
        while !ended { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(sawCancellation)
        #expect(answers.results == [.failed])
    }

    /// The open app shows what the sync fetches, and its own sync may be waiting for this one
    /// (https://github.com/tigerduck-app/tigerduck-app/issues/682).
    @Test("A sync that outlasts the limit goes on while the app is active, and only the limit answers")
    func aSyncPastTheLimitGoesOnWhileTheAppIsActive() async {
        let answers = Answers()
        var sawCancellation: Bool?

        PushAppDelegate.run({
            try? await Task.sleep(for: .milliseconds(300))
            sawCancellation = Task.isCancelled
            return .newData
        }, within: .milliseconds(20), appIsActive: { true }, then: answers.record)
        while sawCancellation == nil { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(sawCancellation == false)
        #expect(answers.results == [.failed])
    }

    @Test("The limit answers while the sync holds the main actor")
    func theLimitAnswersWhileTheMainActorIsBusy() async {
        let answers = Answers()
        let answered = DispatchSemaphore(value: 0)
        var heldUntilAnswered: Bool?

        // The sync lets the main actor go only once the answer is recorded, or after 10 seconds.
        PushAppDelegate.run({
            heldUntilAnswered = Self.hold(until: answered, atMost: 10)
            return .newData
        }, within: .milliseconds(20)) { result in
            answers.record(result)
            answered.signal()
        }
        while heldUntilAnswered == nil { try? await Task.sleep(for: .milliseconds(20)) }

        #expect(heldUntilAnswered == true)
        #expect(answers.results == [.failed])
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
