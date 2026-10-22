import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings push queue", .serialized)
@MainActor
struct NotificationSettingsPushQueueTests {

    private static func resetQueue() {
        NotificationSettingsPushQueue.pendingDebounce?.cancel()
        NotificationSettingsPushQueue.pendingDebounce = nil
        NotificationSettingsPushQueue.tail?.cancel()
        NotificationSettingsPushQueue.tail = nil
        NotificationSettingsPushQueue.generation = 0
    }

    @MainActor
    private final class RanLog {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    @Test("a push already queued when the user logs out never reaches the account that signs in after")
    func logoutStopsAQueuedPushFromCrossingAccounts() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let ran = RanLog()

        let taskA = NotificationSettingsPushQueue.enqueue { ran.append("accountA") }

        NotificationSettingsPushQueue.cancelAll()

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

        NotificationSettingsPushQueue.debounce({
            NotificationSettingsPushQueue.enqueue { ran.append("accountA") }
        }, sleep: { await timer.sleep(for: $0) })
        let debounce = try #require(NotificationSettingsPushQueue.pendingDebounce)
        try await timer.waitUntilArmed()
        #expect(await timer.requestedDurations == [.milliseconds(250)])

        NotificationSettingsPushQueue.cancelAll()

        await timer.fire()
        await debounce.value

        let taskB = NotificationSettingsPushQueue.enqueue { ran.append("accountB") }
        await taskB.value

        #expect(ran.values == ["accountB"])
    }

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
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(
                    ["assignments": ["enabled": !before.isAssignmentReminderEnabled]],
                    revision: 1
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
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
            SettingsAPIStub.enqueue(
                try NotificationSettingsFixtures.found(
                    ["courses": ["enabled": true]],
                    revision: 1
                ),
                for: url
            )
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
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
            let behind = NotificationSettingsPushQueue.enqueue {}
            await task.value
            await behind.value

            #expect(log.wrote == false)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
        }
    }

    @Test("a full sync's copy of the document stands only while no link finishes after its fetch")
    func snapshotCopyOnlyUntilALinkFinishes() async {
        Self.resetQueue()
        defer { Self.resetQueue() }
        let before = NotificationSettingsPushQueue.finishedLinks

        if case .read = NotificationSettingsPushQueue.source(.snapshot(nil), linksBeforeSnapshot: before) {
            Issue.record("nothing ran since the fetch, so the copy is current")
        }

        await NotificationSettingsPushQueue.enqueue {}.value

        guard case .read = NotificationSettingsPushQueue.source(.snapshot(nil), linksBeforeSnapshot: before) else {
            Issue.record("a push that finished after the fetch may have written past the copy")
            return
        }
    }
}

