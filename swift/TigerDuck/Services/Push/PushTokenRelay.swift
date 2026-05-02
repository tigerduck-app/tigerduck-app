import ActivityKit
import Foundation
import os

/// Observes `Activity<TigerDuckActivityAttributes>.pushToStartTokenUpdates`
/// and hands each new token off to `PushRegistrationService`.
///
/// The async sequence is long-lived — we wrap it in a `Task` so callers can
/// start/stop it around app scene lifecycle. iOS itself rotates the PTS
/// token periodically, so we always take the latest value.
///
/// Note: this observes ONLY the push-to-start token. Per-activity update
/// tokens (`activity.pushTokenUpdates`) are out of scope for the MVP since
/// `timerInterval` on-device animation removes the need to push updates.
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
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            logger.info("Live Activities disabled; skipping PTS token relay")
            return
        }

        let registration = self.registration
        let logger = self.logger
        task = Task.detached(priority: .utility) {
            for await tokenData in Activity<TigerDuckActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.map { String(format: "%02x", $0) }.joined()
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
