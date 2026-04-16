import ActivityKit
import Foundation
import os

/// Reflects a resolved `LiveActivitySnapshot` as a single running ActivityKit
/// activity. Maintains the spec invariant: only one Live Activity exists; we
/// start, update, or end it based on what the resolver returns.
///
/// Before phase B ships the Widget Extension UI, calling `apply` does write
/// the snapshot to the shared store and attempt to request an activity, but
/// iOS will reject the request without a matching `ActivityConfiguration` in
/// an extension. That is acceptable — the app side contract stays stable,
/// and the moment the extension lands, the activity will light up.
@MainActor
final class LiveActivityCoordinator {
    private let store: SharedSnapshotStore
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "LiveActivity")

    init(store: SharedSnapshotStore = SharedSnapshotStore()) {
        self.store = store
    }

    /// Apply the resolved snapshot. Starts, updates, or ends the activity as needed.
    func apply(snapshot: LiveActivitySnapshot?) async {
        store.writeSnapshot(snapshot)

        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities are disabled by the system")
            return
        }

        let current = Activity<TigerDuckActivityAttributes>.activities.first

        guard let snapshot else {
            if let current {
                await current.end(nil, dismissalPolicy: .immediate)
            }
            return
        }

        let state = TigerDuckActivityAttributes.ContentState(snapshot: snapshot)
        let content = ActivityContent(state: state, staleDate: snapshot.countdownTarget)

        if let current {
            if current.content.state.snapshot != snapshot {
                await current.update(content)
            }
        } else {
            do {
                _ = try Activity.request(
                    attributes: TigerDuckActivityAttributes(activityId: snapshot.sourceId),
                    content: content,
                    pushType: nil
                )
            } catch {
                logger.error("Failed to start Live Activity: \(error.localizedDescription, privacy: .public)")
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
