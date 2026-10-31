import Defaults
import Foundation
import Observation

/// Runs TigerSync while its switch is on: follows the switch one transition at a time, and runs
/// the outbox's drain on each tick, from the ticker or on request.
@MainActor
@Observable
final class CloudSyncLifecycle {
    private(set) var state: CloudSyncState = .disabled

    @ObservationIgnored private let push: PushCoordinator
    @ObservationIgnored private let outbox: SyncOutbox
    @ObservationIgnored private let edits: QueuedEdits
    @ObservationIgnored private let drain: OutboxDrain
    @ObservationIgnored private let ticker = CloudSyncTicker()

    /// Transitions run multi-step async work with side effects (push enable,
    /// the preference PATCH, outbox clear). MainActor isolation does NOT
    /// serialize across await suspension points, so an interleaved
    /// enable/disable could leave the coordinator active while the push
    /// stack is disabled. Every transition is chained through this task so
    /// they run to completion one at a time.
    @ObservationIgnored private var lifecycleTask: Task<Void, Never>?

    init(push: PushCoordinator, outbox: SyncOutbox, edits: QueuedEdits, drain: OutboxDrain, isEnabled: Bool) {
        self.push = push
        self.outbox = outbox
        self.edits = edits
        self.drain = drain
        if isEnabled {
            state = .active
        }
    }

    func followPreference() {
        enqueueTransition { [weak self] in
            await self?.matchPreference()
        }
    }

    /// A drain the timer, `scheduleTick` or an edit started runs in a task the sign-out does not
    /// cancel, so its request is cancelled here, and `OutboxDrain` sends nothing more for a drain
    /// begun before the sign-out or while it settles.
    func settleForSignOut() async {
        drain.beginSignOut()
        defer { drain.endSignOut() }
        await enqueueTransition { [weak self] in
            await self?.matchPreference()
            await self?.outbox.clearAll()
            self?.edits.forgetDiscards()
        }.value
        await drain.awaitSending()
    }

    private func matchPreference() async {
        switch (Defaults[.cloudSyncEnabled], state) {
        case (true, .disabled):
            await performEnable()
        case (false, .active), (false, .enabling):
            await performDisable()
        default:
            break
        }
    }

    @discardableResult
    private func enqueueTransition(
        _ transition: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let previous = lifecycleTask
        let task = Task { @MainActor in
            await previous?.value
            await transition()
        }
        lifecycleTask = task
        return task
    }

    private func performEnable() async {
        if case .enabling = state { return }
        state = .enabling(step: "register")

        push.enable()
        await push.registration.updateCloudSyncEnabled(true)

        state = .active
        start()
        await syncTick()
    }

    private func performDisable() async {
        stop()

        await push.registration.updateCloudSyncEnabled(false)

        await outbox.clearAll()
        edits.forgetDiscards()

        state = .disabled
    }

    func syncTick() async {
        guard state == .active else { return }
        await drain.run(while: { state == .active })
    }

    func start() {
        ticker.start(
            every: CloudSyncCoordinator.Tunables.tickInterval, tick: { [weak self] in await self?.syncTick() }
        ) { [weak self] in
            guard let self, self.state == .active else { return }
            self.scheduleTick()
        }
    }

    func stop() {
        ticker.stop()
    }

    func scheduleTick(after seconds: TimeInterval = 0) {
        Task { [weak self] in
            if seconds > 0 {
                try? await AppClock.sleep(until: ContinuousClock.now + .seconds(seconds))
            }
            await self?.syncTick()
        }
    }
}
