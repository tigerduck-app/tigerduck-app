import Defaults
import Foundation
import Testing
@testable import TigerDuck

@Suite("Notification settings push queue", .serialized)
@MainActor
struct NotificationSettingsPushQueueTests {

    private static func resetQueue() {
        NotificationSettingsPushQueue.cancelAll()
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

    @Test("a reconcile whose read failed, with nothing unsent, is owed and run again by the next retry")
    func failedReconcileIsOwed() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }
        try await NotificationSettingsFixtures.withStore { store in
            let signIn = AccountSession.school.currentSignIn
            let syncWasOn = Defaults[.cloudSyncEnabled]
            let pendingWas = Defaults[.notificationSettingsPushPending]
            Defaults[.cloudSyncEnabled, for: signIn] = true
            Defaults[.notificationSettingsPushPending, for: signIn] = false
            defer {
                Defaults[.cloudSyncEnabled, for: signIn] = syncWasOn
                Defaults[.notificationSettingsPushPending, for: signIn] = pendingWas
            }
            let baseURL = SettingsAPIStub.uniqueBaseURL()
            let url = NotificationSettingsFixtures.documentURL(baseURL)
            let syncer = NotificationSettingsSyncer(preferences: store) { _ in SettingsAPIStub.makeClient(baseURL: baseURL) }
            SettingsAPIStub.enqueue(.init(statusCode: 500, body: Data()), for: url)

            await syncer.reconcile().value
            #expect(syncer.owesReconcile)

            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found([:], revision: 2), for: url)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 3), for: url)
            syncer.retryUnacknowledged()
            await NotificationSettingsPushQueue.tail?.value

            #expect(SettingsAPIStub.requests(for: url).filter { $0.httpMethod == "GET" }.count == 2)
            #expect(!syncer.owesReconcile)
            let tail = NotificationSettingsPushQueue.tail
            syncer.retryUnacknowledged()
            #expect(NotificationSettingsPushQueue.tail == tail)
        }
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
        var wrote: NotificationSettingsSync.PushResult?
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
                _ = try? await NotificationSettingsReconcile.reconcile(
                    store: store,
                    client: client,
                    cloudSyncEnabled: true,
                    syncAssignmentRemindersEnabled: true,
                    syncLiveActivityEnabled: true,
                    isPushPending: { false },
                    isCurrent: isCurrent
                )
                return .finished
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
                log.outcome = try? await NotificationSettingsReconcile.reconcile(
                    store: store,
                    client: client,
                    cloudSyncEnabled: true,
                    syncAssignmentRemindersEnabled: true,
                    syncLiveActivityEnabled: true,
                    isPushPending: { false },
                    isCurrent: isCurrent
                )
                return .finished
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
                    base: .since(.init(from: store)),
                    client: client,
                    cloudSyncEnabled: true,
                    isCurrent: isCurrent
                )
                return .unsettled
            }
            let behind = NotificationSettingsPushQueue.enqueue {}
            await task.value
            await behind.value

            #expect(log.wrote == .skipped)
            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
        }
    }

    @Test("a logout while a push's write is out: the push reports nothing written, so no synced copy is kept")
    func logoutDuringAPushWriteReportsNothingWritten() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        try await NotificationSettingsFixtures.withStore { store in
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(["courses": ["enabled": true]], revision: 1), for: url)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
            let requestsSent = RanLog()
            let client = SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
                await MainActor.run {
                    requestsSent.append("request")
                    if requestsSent.values.count == 2 { NotificationSettingsPushQueue.cancelAll() }
                }
                return nil
            })
            let log = WriteLog()

            let task = NotificationSettingsPushQueue.enqueuePush { isCurrent in
                log.wrote = try? await NotificationSettingsSync.push(
                    local: .init(from: store),
                    base: .since(.init(from: store)),
                    client: client,
                    cloudSyncEnabled: true,
                    isCurrent: isCurrent
                )
                return .unsettled
            }
            let behind = NotificationSettingsPushQueue.enqueue {}
            await task.value
            await behind.value

            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT"])
            #expect(log.wrote == .skipped)
        }
    }

    @Test("a reconcile that deferred to a pending push runs again once a push lands, and only once")
    func deferredReconcileRunsAgainOnceAPushLands() async {
        Self.resetQueue()
        defer { Self.resetQueue() }
        let ran = RanLog()

        NotificationSettingsPushQueue.enqueueReconcile { _ in
            ran.append("reconcile")
            return ran.values.count == 1 ? .deferredToPendingPush : .finished
        }
        NotificationSettingsPushQueue.enqueuePush { _ in ran.append("push failed"); return .unsettled }
        NotificationSettingsPushQueue.enqueuePush { _ in ran.append("push landed"); return .landedWithNothingLeft }
        await NotificationSettingsPushQueue.enqueuePush { _ in ran.append("push landed"); return .landedWithNothingLeft }.value
        await NotificationSettingsPushQueue.tail?.value

        #expect(ran.values == ["reconcile", "push failed", "push landed", "push landed", "reconcile"])
    }

    @Test("a sign-out drops a reconcile owed to a pending push")
    func signOutDropsTheOwedReconcile() async {
        Self.resetQueue()
        defer { Self.resetQueue() }
        let ran = RanLog()

        await NotificationSettingsPushQueue.enqueueReconcile { _ in ran.append("reconcile"); return .deferredToPendingPush }.value
        NotificationSettingsPushQueue.cancelAll()
        await NotificationSettingsPushQueue.enqueuePush { _ in ran.append("push"); return .landedWithNothingLeft }.value
        await NotificationSettingsPushQueue.tail?.value

        #expect(ran.values == ["reconcile", "push"])
    }

    @MainActor
    private final class SwitchOnLog {
        var pending: Bool
        var outcomes: [NotificationSettingsSync.ReconcileOutcome?] = []
        init(pending: Bool) { self.pending = pending }
    }

    private static let serverSections: [String: Any] = [
        "assignments": ["enabled": true, "reminder_offsets_minutes": [1440]],
        "live_activity": ["show_in_class": false, "class_preparing_lead_seconds": 900, "assignment_lead_seconds": 7200],
        "courses": ["enabled": true, "reminder_offsets_minutes": [10]],
    ]

    private static func enqueueReconcile(
        store: LiveActivityPreferencesStore, client: SettingsDocumentClient, log: SwitchOnLog
    ) {
        NotificationSettingsPushQueue.enqueueReconcile { isCurrent in
            let outcome = try? await NotificationSettingsReconcile.reconcile(
                store: store,
                client: client,
                cloudSyncEnabled: true,
                syncAssignmentRemindersEnabled: true,
                syncLiveActivityEnabled: true,
                isPushPending: { log.pending },
                isCurrent: isCurrent
            )
            log.outcomes.append(outcome)
            return outcome == .deferredToPendingPush ? .deferredToPendingPush : .finished
        }
    }

    @Test("a switch turned on while another push is pending: the section's edit goes up, no stale field does, and the server's section is adopted once that push lands")
    func reenabledSectionIsAdoptedOnceThePendingPushLands() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        let client = SettingsAPIStub.makeClient(baseURL: baseURL)
        try await NotificationSettingsFixtures.withStore { store in
            store.isAssignmentReminderEnabled = false
            store.showInClassScenario = true
            store.classPreparingLeadTime = 1800
            store.assignmentLiveActivityLeadTime = 5400
            let local = NotificationSettingsSync.LocalPreferences(from: store)
            var lagging = local
            lagging.isAssignmentReminderEnabled = true
            lagging.showInClassScenario = false
            let synced = lagging.replacing(.liveActivity, from: local)
            store.assignmentLiveActivityLeadTime = 600
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(Self.serverSections, revision: 2), for: url)
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 3), for: url)
            let log = SwitchOnLog(pending: true)

            Self.enqueueReconcile(store: store, client: client, log: log)
            let push = NotificationSettingsPushQueue.enqueuePush { isCurrent in
                let wrote = (try? await NotificationSettingsSync.push(
                    local: .init(from: store), base: .since(synced), client: client, cloudSyncEnabled: true, isCurrent: isCurrent
                )) ?? .skipped
                guard wrote == .landed, let sent = try? NotificationSettingsFixtures.sentDocument(SettingsAPIStub.requests(for: url)[1]),
                      let afterPush = try? NotificationSettingsFixtures.found(sent, revision: 3)
                else { return .unsettled }
                SettingsAPIStub.enqueue(afterPush, for: url)
                log.pending = false
                return .landedWithNothingLeft
            }
            await push.value
            await NotificationSettingsPushQueue.tail?.value

            let requests = SettingsAPIStub.requests(for: url)
            try #require(requests.map(\.httpMethod) == ["GET", "PUT", "GET"])
            let sent = try NotificationSettingsFixtures.sentDocument(requests[1])
            #expect((sent["assignments"] as? [String: Any])?["enabled"] as? Bool == false)
            let liveActivity = try #require(sent["live_activity"] as? [String: Any])
            #expect(liveActivity["assignment_lead_seconds"] as? Int == 600)
            #expect(liveActivity["show_in_class"] as? Bool == false)
            #expect(liveActivity["class_preparing_lead_seconds"] as? Int == 900)
            #expect(log.outcomes == [.deferredToPendingPush, .settled(adopted: [.assignments, .liveActivity, .courses], seeded: [])])
            #expect(store.assignmentLiveActivityLeadTime == 600)
            #expect(store.showInClassScenario == false)
            #expect(store.classPreparingLeadTime == 900)
            #expect(store.isAssignmentReminderEnabled == false)
        }
    }

    @Test("a switch turned on with nothing pending: the reconcile adopts the server's section at once and sends nothing")
    func reenabledSectionIsAdoptedAtOnceWithNothingPending() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }

        let baseURL = SettingsAPIStub.uniqueBaseURL()
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        try await NotificationSettingsFixtures.withStore { store in
            store.showInClassScenario = true
            store.classPreparingLeadTime = 1800
            SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(Self.serverSections, revision: 2), for: url)
            let log = SwitchOnLog(pending: false)

            Self.enqueueReconcile(store: store, client: SettingsAPIStub.makeClient(baseURL: baseURL), log: log)
            await NotificationSettingsPushQueue.tail?.value

            #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET"])
            #expect(log.outcomes == [.settled(adopted: [.assignments, .liveActivity, .courses], seeded: [])])
            #expect(store.showInClassScenario == false)
            #expect(store.classPreparingLeadTime == 900)
        }
    }

    @Test("a full sync's copy of the document stands only while no link finishes after its fetch")
    func snapshotCopyOnlyUntilALinkFinishes() async {
        Self.resetQueue()
        defer { Self.resetQueue() }
        let before = NotificationSettingsPushQueue.finishedLinks

        if case .read = NotificationSettingsPushQueue.source(.snapshot(.neverWritten), linksBeforeSnapshot: before) {
            Issue.record("nothing ran since the fetch, so the copy is current")
        }

        await NotificationSettingsPushQueue.enqueue {}.value

        guard case .read = NotificationSettingsPushQueue.source(.snapshot(.neverWritten), linksBeforeSnapshot: before) else {
            Issue.record("a push that finished after the fetch may have written past the copy")
            return
        }
    }

    private static func withSyncOn(_ body: (SignIn) async throws -> Void) async rethrows {
        let signIn = AccountSession.school.currentSignIn
        let syncWasOn = Defaults[.cloudSyncEnabled]
        let remindersWereOn = Defaults[.syncAssignmentReminders]
        let liveActivityWasOn = Defaults[.syncLiveActivity]
        let pendingWas = Defaults[.notificationSettingsPushPending]
        let copyWas = Defaults[.notificationSettingsSyncedPreferences]
        let everyFieldWas = Defaults[.notificationSettingsPushSendsEveryField]
        defer {
            Defaults[.cloudSyncEnabled, for: signIn] = syncWasOn
            Defaults[.syncAssignmentReminders] = remindersWereOn
            Defaults[.syncLiveActivity] = liveActivityWasOn
            Defaults[.notificationSettingsPushPending, for: signIn] = pendingWas
            Defaults[.notificationSettingsSyncedPreferences, for: signIn] = copyWas
            Defaults[.notificationSettingsPushSendsEveryField, for: signIn] = everyFieldWas
        }
        Defaults[.cloudSyncEnabled, for: signIn] = true
        Defaults[.syncAssignmentReminders] = true
        Defaults[.syncLiveActivity] = true
        Defaults[.notificationSettingsPushPending, for: signIn] = false
        NotificationSettingsSync.forget()
        try await body(signIn)
    }

    private static func clientTurningOnLiveActivity(
        _ baseURL: URL, store: LiveActivityPreferencesStore, lead: TimeInterval, for signIn: SignIn
    ) -> SettingsDocumentClient {
        let url = NotificationSettingsFixtures.documentURL(baseURL)
        return SettingsAPIStub.makeClient(baseURL: baseURL, authHeaderProvider: {
            await MainActor.run {
                guard SettingsAPIStub.requests(for: url).count == 1 else { return }
                store.classPreparingLeadTime = lead
                NotificationSettingsSync.sectionTurnedOn(.liveActivity, local: .init(from: store), for: signIn)
            }
            return nil
        })
    }

    @Test("a section turned off, edited and on again while a push is out keeps the copy its turn-on made, so the edit gives way")
    func aTurnOnDuringAPushKeepsItsCopy() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }
        try await NotificationSettingsFixtures.withStore { store in
            try await Self.withSyncOn { signIn in
                store.classPreparingLeadTime = 900
                NotificationSettingsSync.seedSyncedCopyOnSignIn(from: .init(from: store), for: signIn)
                store.classPreparingLeadTime = 1800
                let baseURL = SettingsAPIStub.uniqueBaseURL()
                let url = NotificationSettingsFixtures.documentURL(baseURL)
                SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found([:], revision: 1), for: url)
                SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
                let client = Self.clientTurningOnLiveActivity(baseURL, store: store, lead: 3600, for: signIn)
                let syncer = NotificationSettingsSyncer(preferences: store) { _ in client }

                await syncer.push()

                #expect(NotificationSettingsSync.lastSyncedPreferences?.classPreparingLeadTime == 3600)
                try #require(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT"])
                let written = try NotificationSettingsFixtures.sentDocument(SettingsAPIStub.requests(for: url)[1])
                SettingsAPIStub.enqueue(try NotificationSettingsFixtures.found(written, revision: 2), for: url)
                SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 3), for: url)
                await syncer.push()
                #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT", "GET"])
            }
        }
    }

    @Test("a section turned on while a reconcile's write is out keeps the copy its turn-on made")
    func aTurnOnDuringAReconcileWriteKeepsItsCopy() async throws {
        Self.resetQueue()
        defer { Self.resetQueue() }
        try await NotificationSettingsFixtures.withStore { store in
            try await Self.withSyncOn { signIn in
                store.isAssignmentReminderEnabled = false
                store.classPreparingLeadTime = 1800
                NotificationSettingsSync.seedSyncedCopyOnSignIn(from: .init(from: store), for: signIn)
                let baseURL = SettingsAPIStub.uniqueBaseURL()
                let url = NotificationSettingsFixtures.documentURL(baseURL)
                SettingsAPIStub.enqueue(
                    try NotificationSettingsFixtures.found(
                        ["assignments": ["enabled": true], "courses": ["enabled": true]], revision: 1
                    ),
                    for: url
                )
                SettingsAPIStub.enqueue(try NotificationSettingsFixtures.written(revision: 2), for: url)
                let client = Self.clientTurningOnLiveActivity(baseURL, store: store, lead: 3600, for: signIn)
                let syncer = NotificationSettingsSyncer(preferences: store) { _ in client }

                await syncer.reconcile().value

                #expect(SettingsAPIStub.requests(for: url).map(\.httpMethod) == ["GET", "PUT"])
                #expect(NotificationSettingsSync.lastSyncedPreferences?.classPreparingLeadTime == 3600)
                #expect(NotificationSettingsSync.lastSyncedPreferences?.isAssignmentReminderEnabled == true)
            }
        }
    }
}
