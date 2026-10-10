// A notification-settings edit still in the 250 ms debounce or the push chain at logout
// must not land on the next account. These tests enqueue, log out (`cancelAll()`), enqueue
// as another account, and check none of the first batch ran, not just that a flag flipped.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings push queue", .serialized)
@MainActor
struct NotificationSettingsPushQueueTests {

    /// `NotificationSettingsPushQueue`'s statics are process-wide, like
    /// `HolidayUploadQueue`'s — reset to a known baseline before and after
    /// every test so one test's tasks or generation can never leak into
    /// another's.
    private static func resetQueue() {
        NotificationSettingsPushQueue.pendingDebounce?.cancel()
        NotificationSettingsPushQueue.pendingDebounce = nil
        NotificationSettingsPushQueue.tail?.cancel()
        NotificationSettingsPushQueue.tail = nil
        NotificationSettingsPushQueue.generation = 0
    }

    /// Records which "account"'s work actually ran, in order. A plain
    /// `@MainActor` class rather than the lock-based recorder
    /// `NotificationSettingsSyncTests` uses for `NotificationCenter` posts:
    /// the suite, `enqueue`'s `Task`, and every closure below are all
    /// `@MainActor`, so there is no cross-thread access to guard against.
    @MainActor
    private final class RanLog {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    // MARK: - The actual hazard

    @Test("a push already queued when the user logs out never reaches the account that signs in after")
    func logoutStopsAQueuedPushFromCrossingAccounts() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let ran = RanLog()

        // Account A makes an edit — `enqueueNotificationSettingsPush()`
        // would call exactly this. Nothing has run it yet: `enqueue` only
        // chains a `Task`, it does not block.
        let taskA = NotificationSettingsPushQueue.enqueue { ran.append("accountA") }

        // Account A logs out before that link gets a chance to run.
        NotificationSettingsPushQueue.cancelAll()

        // Account B signs in and makes its own edit.
        let taskB = NotificationSettingsPushQueue.enqueue { ran.append("accountB") }

        await taskA.value
        await taskB.value

        #expect(ran.values == ["accountB"])
    }

    @Test("a debounced edit still sleeping when the user logs out never gets far enough to enqueue")
    func debouncedEditQueuedBeforeLogoutNeverReachesNextAccount() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let ran = RanLog()
        let timer = ManualSleeper()

        // What `scheduleNotificationSettingsPush()` debounces: once the wait ends, a push is
        // enqueued.
        NotificationSettingsPushQueue.debounce({
            NotificationSettingsPushQueue.enqueue { ran.append("accountA") }
        }, sleep: { await timer.sleep(for: $0) })
        let debounce = try #require(NotificationSettingsPushQueue.pendingDebounce)
        try await timer.waitUntilArmed()
        #expect(await timer.requestedDurations == [.milliseconds(250)])

        // The account logs out while the debounce is still sleeping.
        NotificationSettingsPushQueue.cancelAll()

        // The cancel ends the wait, as it ends a real `Task.sleep`. Firing as well covers a cancel
        // that never reached the debounce, which would queue "accountA" ahead of the next account.
        await timer.fire()
        await debounce.value

        // The next account signs in and makes its own edit.
        let taskB = NotificationSettingsPushQueue.enqueue { ran.append("accountB") }
        await taskB.value

        #expect(ran.values == ["accountB"])
    }

    // MARK: - Supporting mechanics

    @Test("without a logout in between, a queued push runs normally")
    func queuedPushRunsWithoutCancellation() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let ran = RanLog()
        let task = NotificationSettingsPushQueue.enqueue { ran.append("ok") }
        await task.value

        #expect(ran.values == ["ok"])
    }

    @Test("two pushes queued back to back both run, in order, without a logout")
    func twoQueuedPushesBothRunInOrder() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let ran = RanLog()
        let taskA = NotificationSettingsPushQueue.enqueue { ran.append("first") }
        let taskB = NotificationSettingsPushQueue.enqueue { ran.append("second") }
        await taskA.value
        await taskB.value

        #expect(ran.values == ["first", "second"])
    }

    @Test("cancelAll cancels the sleeping debounce, not just the push chain")
    func cancelAllCancelsPendingDebounce() {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let debounce = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        NotificationSettingsPushQueue.pendingDebounce = debounce

        NotificationSettingsPushQueue.cancelAll()

        #expect(debounce.isCancelled)
        #expect(NotificationSettingsPushQueue.pendingDebounce == nil)
    }

    @Test("cancelAll cancels and clears the tail, and bumps the generation")
    func cancelAllCancelsTailAndBumpsGeneration() {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let generationBefore = NotificationSettingsPushQueue.generation
        let tail = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(60))
        }
        NotificationSettingsPushQueue.tail = tail

        NotificationSettingsPushQueue.cancelAll()

        #expect(tail.isCancelled)
        #expect(NotificationSettingsPushQueue.tail == nil)
        #expect(NotificationSettingsPushQueue.generation == generationBefore + 1)
    }

    // MARK: - Reads of the document ride the same chain

    /// What a queued read of the document came back with.
    @MainActor
    private final class OutcomeLog {
        var outcome: NotificationSettingsSync.ReconcileOutcome?
    }

    private final class WriteLog {
        var wrote: Bool?
    }

    @Test("a logout between queueing a read of the document and running it drops the read")
    func logoutBeforeAQueuedReadRunsDropsIt() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        await NotificationSettingsFixtures.withStore { store in
            let ran = RanLog()

            // Account A's read is queued — at sign-in, say, or as a settings
            // screen opens...
            let task = NotificationSettingsPushQueue.enqueueReconcile { isCurrent in
                ran.append("accountA")
                _ = try? await NotificationSettingsSync.reconcile(
                    store: store,
                    client: client,
                    cloudSyncEnabled: true,
                    syncAssignmentRemindersEnabled: true,
                    syncLiveActivityEnabled: true,
                    isPushPending: { false },
                    isCurrent: isCurrent
                )
            }
            // ...and A logs out before it gets to run.
            NotificationSettingsPushQueue.cancelAll()
            await task.value

            #expect(ran.values.isEmpty)
            #expect(SettingsAPIStub.requests(for: url).isEmpty)
        }
    }

    @Test("a logout while a read is out: nothing it read is applied, and nothing is written")
    func logoutDuringAReadAbandonsIt() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        try await NotificationSettingsFixtures.withStore { store in
            let before = NotificationSettingsSync.LocalPreferences(from: store)
            // Account A's document disagrees with the device and lacks
            // `live_activity`: applied, it would change the store; settled, a
            // write would follow.
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(
                    ["assignments": ["enabled": !before.isAssignmentReminderEnabled]],
                    revision: 1
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
            // A logs out while the read is out: the client asks for its auth
            // header right before sending.
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run { NotificationSettingsPushQueue.cancelAll() }
                return nil
            })
            let log = OutcomeLog()

            let task = NotificationSettingsPushQueue.enqueueReconcile { isCurrent in
                log.outcome = try? await NotificationSettingsSync.reconcile(
                    store: store,
                    client: client,
                    cloudSyncEnabled: true,
                    syncAssignmentRemindersEnabled: true,
                    syncLiveActivityEnabled: true,
                    isPushPending: { false },
                    isCurrent: isCurrent
                )
            }
            // Something queued behind the read, so the read is not the chain's
            // tail: the logout then leaves its request running, and only the
            // generation check can stop what would come after it.
            let behind = NotificationSettingsPushQueue.enqueue {}
            await task.value
            await behind.value

            #expect(log.outcome == .abandoned)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(NotificationSettingsSync.LocalPreferences(from: store) == before)
        }
    }

    @Test("a logout while a push's read is out: nothing is written over the next account's document")
    func logoutDuringAPushReadAbandonsIt() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        try await NotificationSettingsFixtures.withStore { store in
            // Account A's document, and the write that would follow it. Sent,
            // that write would carry A's whole document -- `courses` included
            // -- over whoever signed in since, on their session.
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(
                    ["courses": ["enabled": true]],
                    revision: 1
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
            // A logs out while the read is out: the client asks for its auth
            // header right before sending.
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run { NotificationSettingsPushQueue.cancelAll() }
                return nil
            })
            let log = WriteLog()

            let task = NotificationSettingsPushQueue.enqueuePush { isCurrent in
                log.wrote = try? await NotificationSettingsSync.push(
                    local: .init(from: store),
                    client: client,
                    cloudSyncEnabled: true,
                    isCurrent: isCurrent
                )
            }
            // Queued behind the push, so the push is not the chain's tail and
            // the logout leaves its request running: only the generation check
            // can stop the write that would come after it.
            let behind = NotificationSettingsPushQueue.enqueue {}
            await task.value
            await behind.value

            #expect(log.wrote == false)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
        }
    }
}
