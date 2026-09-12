// `NotificationSettingsPushQueue` (AppState+NotificationSettings.swift) —
// the generation guard and debounce/tail cancellation that keep a queued
// or in-flight notification-settings push from crossing a logout.
//
// Fix round 2, Important 1: the push queue introduced alongside
// `NotificationSettingsSync` copied `enqueueHolidayUpload`'s chained-tail
// shape (`AppState+PushServer.swift`) but not the half of `HolidayUploadQueue`
// that makes chaining safe across a logout — a `generation` counter, bumped
// on logout, that a queued link checks before running. Without it, a
// preference edit still sitting in the 250 ms debounce or the push chain
// when the user logs out can land on whichever account signs in next, once
// a pull (Task 4) makes those preferences carry another account's data.
//
// These tests drive the actual hazard — enqueue work, "log out"
// (`cancelAll()`), enqueue more work as if a different account had signed
// in, and assert none of the first batch ran — rather than only checking
// that `cancelAll()` flips a flag.
//
// Exercises `NotificationSettingsPushQueue` directly, matching
// `NotificationSettingsSync`'s own doc comment: nothing in this test target
// constructs a full `AppState`. The queue's mechanics are `internal` (not
// `private`, unlike `HolidayUploadQueue`) precisely so this suite can reach
// them without one.
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

        // Mirrors `scheduleNotificationSettingsPush()`: a short sleep that,
        // if allowed to finish, enqueues a push.
        NotificationSettingsPushQueue.pendingDebounce = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            guard !Task.isCancelled else { return }
            NotificationSettingsPushQueue.enqueue { ran.append("accountA") }
        }

        // The account logs out while the debounce is still sleeping.
        NotificationSettingsPushQueue.cancelAll()

        // Longer than the debounce's own sleep: if cancellation did not
        // take, "accountA" has already been enqueued — and, with nothing
        // ahead of it in the chain, almost certainly already run — by the
        // time we get here.
        try? await Task.sleep(for: .milliseconds(200))

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

    @Test("a logout between queueing a read of the document and running it drops the read")
    func logoutBeforeAQueuedReadRunsDropsIt() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        let store = LiveActivityPreferencesStore()
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

    @Test("a logout while a read is out: nothing it read is applied, and nothing is written")
    func logoutDuringAReadAbandonsIt() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        let store = LiveActivityPreferencesStore()
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
