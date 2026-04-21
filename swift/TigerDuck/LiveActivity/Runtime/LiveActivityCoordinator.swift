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
/// `apply` touches only the activity matching the current snapshot's
/// composed id. Activities for other slots / scenarios — typically
/// prelaunched by the server for upcoming events — are left alone and
/// auto-dismiss at their own `dismissal-date`. Explicitly ending them
/// here would kill legitimate future Live Activities (e.g. next
/// class's classPreparing) the moment the app opens.
@MainActor
final class LiveActivityCoordinator {
    private let store: SharedSnapshotStore
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    init(store: SharedSnapshotStore = SharedSnapshotStore()) {
        self.store = store
    }

    /// Apply the resolved snapshot. Starts or updates the single activity
    /// matching the target id; never ends unrelated activities.
    func apply(snapshot: LiveActivitySnapshot?) async {
        store.writeSnapshot(snapshot)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            return
        }

        guard let snapshot else {
            // Snapshot cleared — nothing to do for the on-device target.
            // Server-pushed activities continue their own lifecycle.
            return
        }

        let targetId = snapshot.composedActivityId
        let runningActivities = Activity<TigerDuckActivityAttributes>.activities

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

    /// End every running activity unconditionally. Used for logout and
    /// explicit privacy toggles — the user wants nothing on their lock
    /// screen, server-pushed or otherwise.
    func endAll() async {
        for activity in Activity<TigerDuckActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        store.writeSnapshot(nil)
    }
}
