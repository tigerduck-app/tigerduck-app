import ActivityKit
import Foundation
import os

nonisolated struct LiveActivityUpdateTokenRegistration: Sendable {
    let activityId: String
    let updateTokenHex: String
    let snapshot: LiveActivitySnapshot
    /// `snapshot.countdownTarget` in real wall-clock time, converted once here
    /// rather than at each send. Under a frozen debug clock the conversion is
    /// "real now plus the remaining fake interval", so recomputing it on a
    /// retry would push the server's end job out by the whole backoff — a
    /// target ten fake minutes away stays ten minutes away forever.
    let countdownTargetRealTime: Date?

    init(activityId: String, updateTokenHex: String, snapshot: LiveActivitySnapshot) {
        self.activityId = activityId
        self.updateTokenHex = updateTokenHex
        self.snapshot = snapshot
        countdownTargetRealTime = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
    }
}

/// Reflects a resolved `LiveActivitySnapshot` as at most one running
/// `TigerDuckActivityAttributes` activity.
///
/// Scenario-scoped `activityId` (`snapshot.composedActivityId`) is the
/// single source of truth for identity. It keeps the on-device path and
/// the server-push path consistent: a classPreparing activity and its
/// follow-up inClass activity are distinct to ActivityKit, so PTS from
/// the server can start the inClass one without colliding with the
/// classPreparing one that iOS already has running.
///
/// The coordinator owns the client-side single-activity invariant. ActivityKit
/// does not treat `staleDate` as an end signal, and server-started activities
/// are not guaranteed to disappear unless an explicit end path runs. Every
/// foreground refresh therefore prunes expired activities and ends any
/// non-current activity before starting or updating the resolved target.
@MainActor
final class LiveActivityCoordinator {
    private let store: SharedSnapshotStore
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")
    private var automaticEndTasks: [String: Task<Void, Never>] = [:]
    private var activityObserverTask: Task<Void, Never>?
    private var activityUpdateTokenTasks: [String: Task<Void, Never>] = [:]
    /// `Activity.id`s this coordinator has ended. ActivityKit does not
    /// promise that an ended activity has left `Activity.activities` by the
    /// time `end` returns, so a survivor search that trusted
    /// `activityState` alone could pick a copy that is already on its way
    /// out. Pruned of ids ActivityKit no longer lists.
    private var endedActivityIds: Set<String> = []
    private var updateTokenRegistrationHandler: (@Sendable (LiveActivityUpdateTokenRegistration) async -> Void)?

    init(store: SharedSnapshotStore = SharedSnapshotStore()) {
        self.store = store
        startActivityObserver()
    }

    deinit {
        activityObserverTask?.cancel()
        for task in automaticEndTasks.values {
            task.cancel()
        }
        for task in activityUpdateTokenTasks.values {
            task.cancel()
        }
    }

    func setUpdateTokenRegistrationHandler(
        _ handler: @escaping @Sendable (LiveActivityUpdateTokenRegistration) async -> Void
    ) {
        updateTokenRegistrationHandler = handler
    }

    /// Apply the resolved snapshot. Starts or updates the single activity
    /// matching the target id and ends stale or unrelated activities.
    func apply(snapshot: LiveActivitySnapshot?) async {
        let now = AppClock.now()
        await pruneRunningActivities(keeping: snapshot?.composedActivityId, now: now)

        // Persist the snapshot to the App Group AFTER the system gate so
        // a user with Live Activities disabled cannot leave a stale
        // snapshot in shared storage that any background widget read
        // would still surface. When disabled — or no snapshot — we
        // explicitly clear the share so reads see exactly what the
        // user expects.
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            store.writeSnapshot(nil)
            return
        }

        guard let snapshot else {
            store.writeSnapshot(nil)
            cancelAutomaticEndTasks()
            return
        }

        store.writeSnapshot(snapshot)

        let targetId = snapshot.composedActivityId
        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        // `staleDate` is OS-consumed and validated against the real wall
        // clock — passing the raw app-clock `countdownTarget` makes
        // `Activity.request` fail with `ActivityInput error 0` whenever
        // the debug clock points at a real-future date (the staleDate
        // would land days away). Translate to the real instant that maps
        // to the same fake-clock end so the system sees a sensible
        // short-horizon stale marker.
        let realStaleDate = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
        let content = ActivityContent(state: state, staleDate: realStaleDate)

        // A copy this coordinator has just ended can still be listed; it
        // is not the one to update. One the system or the user ended is:
        // updating it is a no-op, and that is the point — the person got
        // rid of it, and the app must not put it back.
        if let matching = runningActivities.first(where: {
            $0.attributes.activityId == targetId && !endedActivityIds.contains($0.id)
        }) {
            if matching.content.state.snapshot != snapshot {
                await matching.update(content)
            }
            observeUpdateToken(for: matching)
            scheduleAutomaticEnd(for: targetId, snapshot: snapshot, now: now)
        } else {
            do {
                let activity = try Activity<TigerDuckActivityAttributes>.request(
                    attributes: TigerDuckActivityAttributes(activityId: targetId),
                    content: content,
                    // Only request a push token when a server-side handler
                    // is wired up to receive it. Otherwise APNs would mint
                    // tokens nothing consumes — and a missing handler is
                    // the legitimate state for users without push enabled.
                    pushType: updateTokenRegistrationHandler == nil ? nil : .token
                )
                observeUpdateToken(for: activity)
                scheduleAutomaticEnd(for: targetId, snapshot: snapshot, now: now)
            } catch {
                logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
                AppLogger.captureError(error, context: [
                    "phase": "liveActivity.requestStart",
                    "activityId": targetId,
                ])
            }
        }
    }

    /// End every running activity unconditionally. Used for logout and
    /// explicit privacy toggles — the user wants nothing on their lock
    /// screen, server-pushed or otherwise.
    func endAll() async {
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            await end(activity, reason: "endAll")
        }
        cancelAutomaticEndTasks()
        cancelUpdateTokenTasks()
        store.writeSnapshot(nil)
    }

    private func startActivityObserver() {
        activityObserverTask = Task { @MainActor [weak self] in
            for await activity in Activity<TigerDuckActivityAttributes>.activityUpdates {
                guard let self else { return }
                let now = AppClock.now()
                await pruneRunningActivities(keeping: nil, now: now, expiredOnly: true)
                // A push-to-start twin of an activity this app already
                // started is ended inside the prune; nothing below is for it.
                if endedActivityIds.contains(activity.id) { continue }
                let snapshot = activity.content.state.snapshot
                if snapshot.countdownTarget.map({ $0 <= now }) == true {
                    await end(activity, reason: "observed expired activity")
                } else {
                    observeUpdateToken(for: activity)
                    scheduleAutomaticEnd(
                        for: activity.attributes.activityId,
                        snapshot: snapshot,
                        now: now
                    )
                }
            }
        }
    }

    private func pruneRunningActivities(
        keeping targetId: String?,
        now: Date,
        expiredOnly: Bool = false
    ) async {
        await endDuplicateActivities(now: now)
        var retainedTaskIds: Set<String> = []
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            // Ended above and still listed: `end(_:reason:)` on it would
            // drop the keeper's observer, which shares its activityId.
            if endedActivityIds.contains(activity.id) { continue }
            let activityId = activity.attributes.activityId
            let isExpired = activity.content.state.snapshot.countdownTarget.map { $0 <= now } ?? false
            let isCurrentTarget = targetId.map { $0 == activityId } ?? false

            if isExpired {
                await end(activity, reason: "countdown expired")
            } else if !expiredOnly, !isCurrentTarget {
                await end(activity, reason: "non-current activity")
            } else {
                retainedTaskIds.insert(activityId)
                observeUpdateToken(for: activity)
                scheduleAutomaticEnd(
                    for: activityId,
                    snapshot: activity.content.state.snapshot,
                    now: now
                )
            }
        }
        cancelAutomaticEndTasks(except: retainedTaskIds)
        cancelUpdateTokenTasks(except: retainedTaskIds)
    }

    /// Keeps one copy of every `activityId` and ends the rest.
    ///
    /// A push-to-start can land for an activity this app already started
    /// itself: it was in the foreground at fire time, so `apply` got there
    /// first. The server skips the push while the activity is registered,
    /// but registration is a round trip and the two can cross. `apply` and
    /// the activity observer both run through here, so a pair is resolved on
    /// whichever comes first.
    ///
    /// The copy whose update token APNs has already minted is kept — it is
    /// the one the server can reach — and the token observer and end timer
    /// are re-pointed at it, because both are keyed by `activityId` and may
    /// still describe a copy that just went away. An observer left on a
    /// dead activity means the survivor's token is never registered, so the
    /// server can neither end it nor see it running. Extras are ended
    /// directly rather than through `end(_:reason:)`, which would drop those
    /// keys instead of re-pointing them.
    private func endDuplicateActivities(now: Date) async {
        let listed = Activity<TigerDuckActivityAttributes>.activities
        endedActivityIds = endedActivityIds.intersection(listed.map(\.id))
        let live = listed.filter {
            ($0.activityState == .active || $0.activityState == .stale)
                && !endedActivityIds.contains($0.id)
        }
        for (activityId, copies) in Dictionary(grouping: live, by: { $0.attributes.activityId })
        where copies.count > 1 {
            let keeper = copies.first { $0.pushToken != nil }
                ?? copies.min { $0.id < $1.id }!
            for copy in copies where copy.id != keeper.id {
                logger.info(
                    "Ending duplicate Live Activity id=\(activityId, privacy: .public) reason=already running"
                )
                endedActivityIds.insert(copy.id)
                await copy.end(nil, dismissalPolicy: .immediate)
            }
            activityUpdateTokenTasks[activityId]?.cancel()
            activityUpdateTokenTasks[activityId] = nil
            observeUpdateToken(for: keeper)
            scheduleAutomaticEnd(
                for: activityId,
                snapshot: keeper.content.state.snapshot,
                now: now
            )
        }
    }

    private func scheduleAutomaticEnd(
        for activityId: String,
        snapshot: LiveActivitySnapshot,
        now: Date
    ) {
        automaticEndTasks[activityId]?.cancel()

        guard let target = snapshot.countdownTarget else {
            automaticEndTasks[activityId] = nil
            return
        }

        // `Task.sleep` runs on the real clock, so translate the fake-clock
        // target to the real instant it maps to. Captured once per the
        // `AppClock.realTime(forApp:)` contract — re-deriving in frozen
        // mode would drift as real time advances while fake time stands
        // still.
        let realTarget = AppClock.realTime(forApp: target)
        let delay = max(0, realTarget.timeIntervalSinceNow) + 1
        automaticEndTasks[activityId] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            await self?.endIfStillExpired(activityId: activityId, target: target)
        }
    }

    private func endIfStillExpired(activityId: String, target: Date) async {
        automaticEndTasks[activityId] = nil
        // Not a copy already ended: `end(_:reason:)` on it would drop the
        // keeper's observer, which shares its activityId.
        guard AppClock.now() >= target,
              let activity = Activity<TigerDuckActivityAttributes>.activities.first(where: {
                  $0.attributes.activityId == activityId && !endedActivityIds.contains($0.id)
              }) else {
            return
        }
        await end(activity, reason: "automatic countdown end")
    }

    private func end(
        _ activity: Activity<TigerDuckActivityAttributes>,
        reason: String
    ) async {
        let activityId = activity.attributes.activityId
        logger.info(
            "Ending Live Activity id=\(activityId, privacy: .public) reason=\(reason, privacy: .public)"
        )
        await activity.end(nil, dismissalPolicy: .immediate)
        automaticEndTasks[activityId]?.cancel()
        automaticEndTasks[activityId] = nil
        activityUpdateTokenTasks[activityId]?.cancel()
        activityUpdateTokenTasks[activityId] = nil
    }

    private func cancelAutomaticEndTasks(except retainedIds: Set<String> = []) {
        for activityId in Array(automaticEndTasks.keys) where !retainedIds.contains(activityId) {
            automaticEndTasks[activityId]?.cancel()
            automaticEndTasks[activityId] = nil
        }
    }

    private func observeUpdateToken(for activity: Activity<TigerDuckActivityAttributes>) {
        let activityId = activity.attributes.activityId
        // Skip if we're already observing this activity. The previous
        // implementation also fired an unconditional fire-and-forget
        // registration Task on every call — `observeUpdateToken` is
        // invoked from `apply`, `pruneRunningActivities`, and the
        // activity observer's loop, so server registration was hit
        // O(refresh × activities) times per session. The gated stream
        // below already drains `pushTokenUpdates` *and* registers the
        // current token on first iteration, so the unconditional
        // re-register is redundant.
        guard activityUpdateTokenTasks[activityId] == nil else { return }
        activityUpdateTokenTasks[activityId] = Task { @MainActor [weak self] in
            await self?.registerCurrentUpdateToken(for: activity)
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.registerUpdateToken(
                    activityId: activityId,
                    tokenData: tokenData,
                    snapshot: activity.content.state.snapshot
                )
            }
            // The stream ends with the activity. Leave the slot free so a
            // later activity under the same id (the same class next week,
            // started by push) is observed rather than turned away by the
            // guard above. A cancelled task has been replaced already and
            // must not clear its successor.
            guard !Task.isCancelled else { return }
            self?.activityUpdateTokenTasks[activityId] = nil
        }
    }

    private func registerCurrentUpdateToken(
        for activity: Activity<TigerDuckActivityAttributes>
    ) async {
        guard let tokenData = activity.pushToken else { return }
        await registerUpdateToken(
            activityId: activity.attributes.activityId,
            tokenData: tokenData,
            snapshot: activity.content.state.snapshot
        )
    }

    private func registerUpdateToken(
        activityId: String,
        tokenData: Data,
        snapshot: LiveActivitySnapshot
    ) async {
        guard let updateTokenRegistrationHandler else { return }
        let tokenHex = tokenData.hexEncodedString()
        await updateTokenRegistrationHandler(
            LiveActivityUpdateTokenRegistration(
                activityId: activityId,
                updateTokenHex: tokenHex,
                snapshot: snapshot
            )
        )
    }

    private func cancelUpdateTokenTasks(except retainedIds: Set<String> = []) {
        for activityId in Array(activityUpdateTokenTasks.keys) where !retainedIds.contains(activityId) {
            activityUpdateTokenTasks[activityId]?.cancel()
            activityUpdateTokenTasks[activityId] = nil
        }
    }
}
