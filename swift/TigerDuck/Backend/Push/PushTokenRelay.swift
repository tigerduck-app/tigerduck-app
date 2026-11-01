#if os(iOS)
import ActivityKit
import Foundation
import os

@MainActor
final class PushTokenRelay {
    private let registration: PushRegistrationService
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
            guard await Self.waitUntilActivitiesEnabled(logger: logger) else { return }
            for await tokenData in Activity<TigerDuckActivityAttributes>.pushToStartTokenUpdates {
                let hex = tokenData.hexEncodedString()
                logger.info("received PTS token (len=\(hex.count, privacy: .public))")
                await registration.update(ptsTokenHex: hex)
            }
            logger.info("PTS token stream ended")
        }
    }

    private nonisolated static func waitUntilActivitiesEnabled(logger: Logger) async -> Bool {
        let authorization = ActivityAuthorizationInfo()
        guard !authorization.areActivitiesEnabled else { return true }
        logger.info("Live Activities disabled; relaying the PTS token once they are enabled")
        for await isEnabled in authorization.activityEnablementUpdates where isEnabled {
            logger.info("Live Activities enabled; starting PTS token relay")
            return true
        }
        return false
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
