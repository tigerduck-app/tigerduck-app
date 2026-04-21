import ActivityKit
import Foundation
import os

/// Reflects a resolved `LiveActivitySnapshot` as at most one running
/// `TigerDuckActivityAttributes` activity per `(scenario, sourceId)` pair.
///
/// Scenario-scoped `activityId` (`snapshot.composedActivityId`) is the
/// single source of truth for identity. It keeps the on-device path and
/// the server-push path consistent: a classPreparing activity and its
/// follow-up inClass activity are distinct to ActivityKit, so PTS from
/// the server can start the inClass one without colliding with the
/// classPreparing one that iOS already has running.
///
/// `apply` enforces the single-activity invariant *within* a matching
/// `composedActivityId`: any activity whose id does NOT match the current
/// snapshot's target id is ended immediately before we create / update
/// the target.
@MainActor
final class LiveActivityCoordinator {
    private let store: SharedSnapshotStore
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    init(store: SharedSnapshotStore = SharedSnapshotStore()) {
        self.store = store
    }

    /// Apply the resolved snapshot. Starts, updates, or ends activities as needed.
    func apply(snapshot: LiveActivitySnapshot?) async {
        store.writeSnapshot(snapshot)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            return
        }

        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

        guard let snapshot else {
            for activity in runningActivities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let targetId = snapshot.composedActivityId

        // End every activity whose id does not match the current target.
        // Different scenario or different slot → stop it before spinning up
        // the new one. `end(nil, .immediate)` is safe when the activity
        // has already been auto-dismissed by a push dismissal-date.
        for activity in runningActivities where activity.attributes.activityId != targetId {
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        let content = ActivityContent(state: state, staleDate: snapshot.countdownTarget)

        if let matching = runningActivities.first(where: { $0.attributes.activityId == targetId }) {
            if matching.content.state.snapshot != snapshot {
                await matching.update(content)
            }
        } else {
            do {
                _ = try Activity.request(
                    attributes: TigerDuckActivityAttributes(activityId: targetId),
                    content: content,
                    pushType: nil
                )
            } catch {
                logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
                AppLogger.captureError(error, context: [
                    "phase": "liveActivity.requestStart",
                    "activityId": targetId,
                ])
            }
        }
    }

    /// End any running activity unconditionally (e.g. on logout or privacy toggle).
    func endAll() async {
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        store.writeSnapshot(nil)
    }
}
