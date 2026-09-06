import Defaults
import Foundation
import Observation
import os
#if canImport(UIKit)
import UIKit
#endif

// MARK: - State

nonisolated enum CloudSyncState: Equatable, Sendable {
    case disabled
    case enabling(step: String)
    case active
}

// MARK: - CloudSyncCoordinator

/// Owns the cloud-sync lifecycle: enable/disable state machine,
/// periodic sync ticks, local-edit observers that feed the outbox,
/// and outbox drain with retry. Delegates actual API calls to the
/// existing PushCoordinator.
///
/// Architecture by xinshoutw — adapted for the v3-backend branch.
@MainActor
@Observable
final class CloudSyncCoordinator {

    // MARK: Tunables

    enum Tunables {
        static let dataUpdateDebounce: TimeInterval = 30
        static let tickInterval: TimeInterval = 5 * 60
    }

    // MARK: Observable state

    private(set) var state: CloudSyncState = .disabled
    private(set) var lastSyncedAt: Date?
    private(set) var lastError: String?

    // MARK: Shared instance

    private(set) static weak var shared: CloudSyncCoordinator?

    static func registerShared(_ coordinator: CloudSyncCoordinator) {
        shared = coordinator
    }

    // MARK: Dependencies

    @ObservationIgnored private let pushCoordinator: PushCoordinator
    @ObservationIgnored let outbox: SyncOutbox
    @ObservationIgnored private let logger = Logger(
        subsystem: "org.ntust.app.TigerDuck", category: "CloudSync.Coordinator")

    // MARK: Internal state

    @ObservationIgnored private var tickInFlight = false
    @ObservationIgnored var started = false

    // Observer plumbing
    @ObservationIgnored var notificationTokens: [NSObjectProtocol] = []
    @ObservationIgnored var tickTimer: Timer?
    @ObservationIgnored var dataDebounceTask: Task<Void, Never>?

    // MARK: Init

    init(
        pushCoordinator: PushCoordinator,
        outbox: SyncOutbox = SyncOutbox()
    ) {
        self.pushCoordinator = pushCoordinator
        self.outbox = outbox

        if Defaults[.cloudSyncEnabled] {
            state = .active
        }
        let ts = Defaults[.cloudSyncLastSyncedAt]
        lastSyncedAt = ts > 0 ? Date(timeIntervalSince1970: ts) : nil
    }

    // MARK: - Lifecycle serialization

    /// enable()/disable() run multi-step async work with side effects (push
    /// enable/disable, outbox clear). MainActor isolation does NOT serialize
    /// across await suspension points, so an interleaved enable/disable could
    /// leave the coordinator active while the push stack is disabled. Chain
    /// every lifecycle transition through this task so they run to completion
    /// one at a time — the last toggle wins.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?
    private enum LifecycleOp { case enable, disable }

    private func runLifecycle(_ op: LifecycleOp) async {
        let previous = lifecycleTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            switch op {
            case .enable: await self?.performEnable()
            case .disable: await self?.performDisable()
            }
        }
        lifecycleTask = task
        await task.value
    }

    // MARK: - Enable

    func enable() async {
        await runLifecycle(.enable)
    }

    private func performEnable() async {
        if case .enabling = state { return }
        state = .enabling(step: "register")
        lastError = nil

        pushCoordinator.enable()

        do {
            await pushCoordinator.registration.updateCloudSyncEnabled(true)
            state = .enabling(step: "sync")
            try await pullFullSync()
            Defaults[.cloudSyncLastSyncedAt] = Date().timeIntervalSince1970
            lastSyncedAt = Date()
        } catch {
            lastError = String(describing: error)
            AppLogger.captureError(error, context: ["phase": "cloudSync.enable"])
        }

        Defaults[.cloudSyncEnabled] = true
        state = .active
        // Start even when the initial pull failed (e.g. enabled while
        // offline): the timer and observers are how sync self-heals, and
        // a relaunch would start them in this state anyway.
        start()
        // Flush any edits queued during the .enabling pull window now that
        // we're active (their scheduleTick fired while draining was gated).
        await drainOutbox()
    }

    // MARK: - Disable

    func disable() async {
        await runLifecycle(.disable)
    }

    private func performDisable() async {
        stop()

        // Leave the push stack up: the device stays registered with
        // cloud_sync_enabled=false so bulletins and Live Activities keep
        // working, and the Push Server toggle keeps telling the truth.
        // (Relaunch re-enabled push anyway, so tearing it down here only
        // ever produced a temporary mismatch.)
        await pushCoordinator.registration.updateCloudSyncEnabled(false)

        await outbox.clearAll()

        Defaults[.cloudSyncEnabled] = false
        Defaults[.cloudSyncLastSyncedAt] = 0
        lastSyncedAt = nil
        lastError = nil
        state = .disabled
    }

    // MARK: - Sync tick

    func syncTick() async {
        guard state == .active, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        do {
            try await pullFullSync()
        } catch {
            // 401 means the JWT lapsed; AppState's relogin machinery
            // refreshes it, so retry on a later tick like any transient.
            // Blocking here would also drop local edits from the queue.
            if error is URLError || isUnauthorized(error) { return }
            lastError = String(describing: error)
        }

        guard state == .active else { return }

        await outbox.drain { [weak self] op in
            guard let self else { throw CancellationError() }
            try await self.execute(op)
        }

        guard state == .active else { return }

        Defaults[.cloudSyncLastSyncedAt] = Date().timeIntervalSince1970
        lastSyncedAt = Date()
    }

    /// Called by the revision poller when the server revision is ahead.
    /// The caller has already pulled and applied server data via
    /// `syncOverridesFromBackend()`, so only the push half runs here.
    func onRevisionChanged() async {
        await drainOutbox()
    }

    /// Called when a sync_trigger push notification arrives. Same contract
    /// as `onRevisionChanged()`: the pull already happened, push only.
    func onSyncTrigger() async {
        await drainOutbox()
    }

    /// Push half of `syncTick()`: drain pending outbox entries without the
    /// full-sync pull. The pull would be redundant here (the caller just
    /// pulled), and a transient pull failure must not abort the drain.
    private func drainOutbox() async {
        guard state == .active, !tickInFlight else { return }
        tickInFlight = true
        defer { tickInFlight = false }

        guard await outbox.pendingCount() > 0 else { return }

        await outbox.drain { [weak self] op in
            guard let self else { throw CancellationError() }
            try await self.execute(op)
        }
    }

    // MARK: - Enqueue helpers

    func enqueueCourseColorOverride(moodleId: String, semester: String, colorHex: String) {
        // Accept edits during the enable() pull window (.enabling) too: the op
        // queues durably in the outbox and drains once state flips to .active.
        // Gating on == .active would silently drop them.
        guard state != .disabled else { return }
        let op = SyncOp.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: nil, colorHex: colorHex, locale: nil, stamp: Date())
        Task { await outbox.enqueue(op) }
    }

    func enqueueCourseNameOverride(moodleId: String, semester: String, customName: String, locale: String?) {
        guard state != .disabled else { return }
        let op = SyncOp.courseOverride(
            semester: semester, moodleId: moodleId,
            customName: customName, colorHex: nil, locale: locale, stamp: Date())
        Task { await outbox.enqueue(op) }
    }

    /// Awaitable so callers can key "op is durably queued" transitions
    /// (e.g. AppState's pending-override conflict guard) off completion.
    func enqueueAssignmentOverride(moodleCourseId: Int, moodleAssignmentId: Int, localStatus: String) async {
        guard state != .disabled else { return }
        let op = SyncOp.assignmentOverride(
            moodleCourseId: moodleCourseId,
            moodleAssignmentId: moodleAssignmentId,
            localStatus: localStatus, stamp: Date())
        await outbox.enqueue(op)
    }

    /// Moodle assignment ids (as strings) with a queued outbox op that has
    /// not yet reached the server. Conflict detection must treat these as
    /// local-pending rather than cross-device conflicts.
    func pendingAssignmentOverrideIds() async -> Set<String> {
        var ids = Set<String>()
        for entry in await outbox.snapshot() {
            if case .assignmentOverride(_, let moodleAssignmentId, _, _) = entry.op {
                ids.insert(String(moodleAssignmentId))
            }
        }
        return ids
    }

    // MARK: - Pull

    /// Fetch the full sync payload. Applying server data to local caches is
    /// AppState's job (via `syncOverridesFromBackend`); this pull validates
    /// connectivity and auth before the outbox drain.
    private func pullFullSync() async throws {
        _ = try await pushCoordinator.fetchFullSync()
    }

    // MARK: - Execute resolved op

    /// 401s are rethrown as `SyncOutboxAuthError` so the drain aborts and
    /// retains the queue without burning retry attempts — the token layer
    /// refreshes the JWT, and a later tick delivers the ops.
    private func execute(_ op: ResolvedSyncOp) async throws {
        do {
            switch op {
            case .courseOverride(let courseId, let colorHex, let customName, let locale):
                _ = try await pushCoordinator.patchCourseOverride(
                    moodleCourseId: courseId,
                    colorHex: colorHex,
                    customName: customName,
                    locale: locale)

            case .assignmentOverride(let assignmentId, let localStatus):
                _ = try await pushCoordinator.patchAssignmentOverride(
                    moodleAssignmentId: String(assignmentId),
                    localStatus: localStatus)
            }
        } catch {
            if isUnauthorized(error) {
                throw SyncOutboxAuthError(statusCode: 401)
            }
            throw error
        }
    }

    // MARK: - Observers

    func start() {
        guard !started else { return }
        started = true

        attachObservers()

        let timer = Timer.scheduledTimer(withTimeInterval: Tunables.tickInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.syncTick()
            }
        }
        tickTimer = timer
    }

    func stop() {
        tickTimer?.invalidate()
        tickTimer = nil
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
        notificationTokens = []
        dataDebounceTask?.cancel()
        dataDebounceTask = nil
        started = false
    }

    private func attachObservers() {
        let center = NotificationCenter.default

        func observe(_ name: Notification.Name, handler: @escaping @MainActor () -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { handler() }
            }
            notificationTokens.append(token)
        }

        #if canImport(UIKit)
        observe(UIApplication.didBecomeActiveNotification) { [weak self] in
            guard let self, self.state == .active else { return }
            self.scheduleTick()
        }
        #endif
    }

    // MARK: - Helpers

    func scheduleTick(after seconds: TimeInterval = 0) {
        Task { [weak self] in
            if seconds > 0 {
                try? await Task.sleep(for: .seconds(seconds))
            }
            await self?.syncTick()
        }
    }

    private func isUnauthorized(_ error: Error) -> Bool {
        if case PushAPIError.httpStatus(401, _) = error { return true }
        return false
    }
}


// MARK: - Defaults keys

extension Defaults.Keys {
    static let cloudSyncLastSyncedAt = Key<TimeInterval>("cloudSyncLastSyncedAt", default: 0)
}
