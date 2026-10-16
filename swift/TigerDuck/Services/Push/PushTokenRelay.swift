#if os(iOS)
import ActivityKit
import Foundation
import os

/// Observes `Activity<TigerDuckActivityAttributes>.pushToStartTokenUpdates`
/// and hands each new token to `PushRegistrationService`. iOS rotates the
/// token, so the latest value wins. Per-activity update tokens
/// (`activity.pushTokenUpdates`) are not observed here.
///
/// A PTS token exists only while Live Activities are enabled, which the user
/// can change in iOS Settings at any time, so `start()` waits for that rather
/// than returning: `PushCoordinator` starts the relay once per process.
@MainActor
final class PushTokenRelay {
    private let registration: PushRegistrationService
    // nonisolated(unsafe) so deinit (non-isolated) can cancel without
    // violating Swift 6 strict concurrency. Mutations stay on MainActor
    // through start()/stop(), and Task is itself thread-safe.
    private nonisolated(unsafe) var task: Task<Void, Never>?
    private let logger = Logger(subsystem: "org.ntust.app.TigerDuck", category: "Push.Relay")

    init(registration: PushRegistrationService) {
        self.registration = registration
    }

    func start() {
        guard task == nil else { return }

        let registration = self.registration
        let logger = self.logger
        task = Task.detached(priority: .utility) {
            let authorization = ActivityAuthorizationInfo()
            if !authorization.areActivitiesEnabled {
                logger.info("Live Activities disabled; relaying the PTS token once they are enabled")
                var enabled = false
                for await isEnabled in authorization.activityEnablementUpdates where isEnabled {
                    enabled = true
                    break
                }
                // Ending without a `true` means `stop()` cancelled this task
                // or the sequence finished; either way there is nothing to
                // relay.
                guard enabled else { return }
                logger.info("Live Activities enabled; starting PTS token relay")
            }
            for await tokenData in Activity<TigerDuckActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.hexEncodedString()
                logger.info("received PTS token (len=\(hex.count, privacy: .public))")
                await registration.update(ptsTokenHex: hex)
            }
            logger.info("PTS token stream ended")
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
#endif
