import ActivityKit
import Foundation
import os

nonisolated struct LiveActivityUpdateTokenRegistration: Sendable {
    let activityId: String
    let updateTokenHex: String
    let snapshot: LiveActivitySnapshot
    let countdownTargetRealTime: Date?

    init(activityId: String, updateTokenHex: String, snapshot: LiveActivitySnapshot) {
        self.activityId = activityId
        self.updateTokenHex = updateTokenHex
        self.snapshot = snapshot
        countdownTargetRealTime = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
    }
}

/// ActivityKit does not end an activity at `staleDate`, so the prune ends the ones `endReason`
/// and `duplicateInstanceIdsToEnd` pick.
@MainActor
final class LiveActivityCoordinator {
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")
    private let tasks = LiveActivityTasks()
    private var activityObserverTask: Task<Void, Never>?
    /// ActivityKit does not promise that an ended activity has left `Activity.activities` by the
    /// time `end` returns, so a survivor search that trusted `activityState` alone could pick a
    /// copy on its way out.
    private var endedActivityIds: Set<String> = []
    private var conditions = LiveActivityEndRules.Conditions()

    init() {
        startActivityObserver()
        // `activityUpdates` does not report an activity the backend started before this
        // coordinator was built, as before the first unlock, so its token would wait for an apply.
        Task { [weak self] in await self?.pruneRunningActivities(now: AppClock.now()) }
    }

    deinit {
        activityObserverTask?.cancel()
    }

    func setUpdateTokenRegistrationHandler(
        _ handler: @escaping @Sendable (LiveActivityUpdateTokenRegistration) async -> Void
    ) {
        tasks.tokenHandler = handler
    }

    func setAvailabilityProvider(_ provider: @escaping () -> Bool) {
        conditions.isAvailable = provider
        tasks.isAvailable = provider
    }

    func setQuietDayProvider(_ provider: @escaping (Date) -> Bool) {
        conditions.isQuietDay = provider
    }

    func setAssignmentOutstandingProvider(_ provider: @escaping (String) -> Bool?) {
        conditions.isAssignmentOutstanding = provider
    }

    func setSkippedClassProvider(_ provider: @escaping (String) -> Bool) {
        conditions.isSkipped = provider
    }

    func apply(snapshot: LiveActivitySnapshot?) async {
        let now = AppClock.now()
        await pruneRunningActivities(now: now)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            return
        }

        guard let snapshot, conditions.canStart(snapshot) else { return }

        let targetId = snapshot.composedActivityId
        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        // The OS checks `staleDate` against the real clock. The raw app-clock `countdownTarget`,
        // under a debug clock set to a future date, makes `Activity.request` fail with
        // `ActivityInput error 0`; pass the real instant that maps to the same fake-clock end.
        let realStaleDate = snapshot.countdownTarget.map(AppClock.realTime(forApp:))
        let content = ActivityContent(state: state, staleDate: realStaleDate)

        if let matching = updatableCopy(of: targetId, among: runningActivities) {
            if matching.content.state.snapshot != snapshot {
                await matching.update(content)
            }
            tasks.watchToken(of: matching)
            scheduleAutomaticEnd(for: targetId, snapshot: snapshot)
        } else {
            do {
                let activity = try Activity<TigerDuckActivityAttributes>.request(
                    attributes: TigerDuckActivityAttributes(activityId: targetId),
                    content: content,
                    pushType: tasks.tokenHandler == nil ? nil : .token
                )
                tasks.watchToken(of: activity)
                scheduleAutomaticEnd(for: targetId, snapshot: snapshot)
            } catch {
                logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .private)")
                AppLogger.captureError(error, context: [
                    "phase": "liveActivity.requestStart",
                    "activityId": targetId,
                ])
            }
        }
    }

    func endAll() async {
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            await end(activity, reason: "endAll")
        }
        tasks.cancelAll()
    }

    private func startActivityObserver() {
        activityObserverTask = Task { @MainActor [weak self] in
            for await activity in Activity<TigerDuckActivityAttributes>.activityUpdates {
                guard let self else { return }
                let now = AppClock.now()
                await pruneRunningActivities(now: now)
                if endedActivityIds.contains(activity.id) { continue }
                if let reason = conditions.endReason(for: activity, now: now, isAvailable: conditions.isAvailable()) {
                    await end(activity, reason: reason.rawValue)
                    continue
                }
                tasks.watchToken(of: activity)
                scheduleAutomaticEnd(for: activity.attributes.activityId, snapshot: activity.content.state.snapshot)
            }
        }
    }

    private func pruneRunningActivities(now: Date) async {
        let available = conditions.isAvailable()
        endedActivityIds = endedActivityIds.intersection(
            Activity<TigerDuckActivityAttributes>.activities.map(\.id)
        )
        if available {
            await endDuplicateActivities()
        }
        let listed = Activity<TigerDuckActivityAttributes>.activities
        var retainedTaskIds: Set<String> = []
        for activity in listed {
            if endedActivityIds.contains(activity.id) { continue }
            let activityId = activity.attributes.activityId

            if let reason = conditions.endReason(for: activity, now: now, isAvailable: available) {
                await end(activity, reason: reason.rawValue)
            } else {
                retainedTaskIds.insert(activityId)
                tasks.watchToken(of: activity)
                scheduleAutomaticEnd(for: activityId, snapshot: activity.content.state.snapshot)
            }
        }
        tasks.cancelAll(except: retainedTaskIds)
    }

    private func endDuplicateActivities() async {
        let listed = Activity<TigerDuckActivityAttributes>.activities
        let live = listed.filter {
            ($0.activityState == .active || $0.activityState == .stale)
                && !endedActivityIds.contains($0.id)
        }
        let toEnd = Set(LiveActivityEndRules.duplicateInstanceIdsToEnd(live.map(LiveActivityEndRules.facts(of:))))
        guard !toEnd.isEmpty else { return }

        for (activityId, copies) in Dictionary(
            grouping: live, by: { $0.attributes.activityId }
        ) {
            let doomed = copies.filter { toEnd.contains($0.id) }
            guard !doomed.isEmpty,
                  let keeper = copies.first(where: { !toEnd.contains($0.id) })
            else { continue }
            for copy in doomed {
                logger.info(
                    "Ending duplicate Live Activity id=\(activityId, privacy: .private) reason=already running"
                )
                await recordAndEnd(copy)
            }
            tasks.cancelTokenWatch(activityId)
            tasks.watchToken(of: keeper)
            scheduleAutomaticEnd(for: activityId, snapshot: keeper.content.state.snapshot)
        }
    }

    private func scheduleAutomaticEnd(for activityId: String, snapshot: LiveActivitySnapshot) {
        tasks.scheduleEnd(for: activityId, snapshot: snapshot) { [weak self] target in
            await self?.endIfStillExpired(activityId: activityId, target: target)
        }
    }

    private func endIfStillExpired(activityId: String, target: Date) async {
        tasks.endTimerFired(for: activityId)
        guard AppClock.now() >= target,
              let activity = updatableCopy(of: activityId, among: Activity<TigerDuckActivityAttributes>.activities) else {
            return
        }
        await end(activity, reason: "automatic countdown end")
    }

    private func updatableCopy(
        of activityId: String, among running: [Activity<TigerDuckActivityAttributes>]
    ) -> Activity<TigerDuckActivityAttributes>? {
        running.first { $0.attributes.activityId == activityId && !endedActivityIds.contains($0.id) }
    }

    private func end(
        _ activity: Activity<TigerDuckActivityAttributes>,
        reason: String
    ) async {
        let activityId = activity.attributes.activityId
        logger.info(
            "Ending Live Activity id=\(activityId, privacy: .private) reason=\(reason, privacy: .public)"
        )
        await recordAndEnd(activity)
        tasks.cancel(activityId)
    }

    private func recordAndEnd(_ activity: Activity<TigerDuckActivityAttributes>) async {
        endedActivityIds.insert(activity.id)
        await activity.end(nil, dismissalPolicy: .immediate)
    }
}
