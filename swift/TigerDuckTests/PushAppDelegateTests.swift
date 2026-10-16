#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import TigerDuck

/// The backend's `sync_trigger` push wakes the app in the background, where iOS waits a limited
/// time for the completion handler (https://github.com/tigerduck-app/tigerduck-app/issues/449).
@MainActor
struct PushAppDelegateTests {
    @Test("The app declares the Remote notifications background mode, so a sync trigger reaches it in the background")
    func theAppDeclaresRemoteNotifications() {
        let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String]
        #expect(modes?.contains("remote-notification") == true)
    }

    @Test("A sync trigger runs the sync and is answered with new data when it ends")
    func aSyncTriggerIsAnsweredWhenItsSyncEnds() async {
        let delegate = PushAppDelegate()
        var synced = false
        delegate.onSyncTrigger = { synced = true }

        let result = await withCheckedContinuation { continuation in
            delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "sync_trigger"]) {
                continuation.resume(returning: $0)
            }
        }

        #expect(synced)
        #expect(result == .newData)
    }

    @Test("A sync that outlasts the limit is answered at the limit, and not again when it ends")
    func aSyncPastTheLimitIsAnsweredOnceAtTheLimit() async {
        var results: [UIBackgroundFetchResult] = []
        var ended = false

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            PushAppDelegate.run({
                try? await Task.sleep(for: .milliseconds(300))
                ended = true
            }, within: .milliseconds(20)) { result in
                results.append(result)
                if results.count == 1 { continuation.resume() }
            }
        }
        #expect(results == [.failed])
        #expect(!ended)

        while !ended { try? await Task.sleep(for: .milliseconds(20)) }
        #expect(results == [.failed])
    }

    @Test("Another push, or a sync trigger before a sync is bound, is answered at once with no data")
    func otherPushesAreAnsweredWithNoData() {
        let delegate = PushAppDelegate()
        var results: [UIBackgroundFetchResult] = []

        delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "sync_trigger"]) {
            results.append($0)
        }
        delegate.onSyncTrigger = { Issue.record("a push that is no sync trigger ran a sync") }
        delegate.application(UIApplication.shared, didReceiveRemoteNotification: ["kind": "bulletin"]) {
            results.append($0)
        }

        #expect(results == [.noData, .noData])
    }
}
#endif
