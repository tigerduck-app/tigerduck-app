#if os(iOS)
import Foundation
import os

nonisolated enum ActivityTokenRegistration {
    typealias Registrations = PushRegistrationService.ActivityRegistrations

    static func flushPending(on service: isolated PushRegistrationService) async {
        for registration in Array(service.activities.pending.values) {
            await perform(registration, on: service)
        }
    }

    static func perform(
        _ registration: LiveActivityUpdateTokenRegistration, on service: isolated PushRegistrationService
    ) async {
        let logger = service.logger
        do {
            try await service.requests.registerActivity(registration)
            service.activities.landed(registration)
        } catch let error as PushAPIError {
            if case .httpStatus(404, _, _) = error {
                let activityId = registration.activityId
                let attempts = service.activities.countNotFound(activityId)
                if attempts <= Registrations.maxNotFoundAttempts {
                    service.registerIfReady()
                    logger.error("live activity token register 404 attempt=\(attempts, privacy: .public) id=\(activityId, privacy: .private) — re-registering device")
                    return
                }
                logger.error("live activity token register 404 exhausted attempts=\(attempts, privacy: .public) id=\(activityId, privacy: .private) — falling back to backoff retry")
            }
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .private)")
            scheduleRetry(registration, on: service)
        } catch {
            logger.error("live activity token register failed: \(error.localizedDescription, privacy: .private)")
            scheduleRetry(registration, on: service)
        }
    }

    private static func scheduleRetry(
        _ registration: LiveActivityUpdateTokenRegistration, on service: isolated PushRegistrationService
    ) {
        let activityId = registration.activityId
        let attempt = service.activities.countAttempt(activityId)
        guard attempt < Registrations.maxAttempts else {
            service.logger.error(
                "giving up on live activity token register attempts=\(attempt, privacy: .public) id=\(activityId, privacy: .private)"
            )
            service.activities.giveUp(activityId)
            return
        }
        let delay = PushRegistrationService.retryDelay(attempt: attempt)
        service.activities.retryTasks[activityId]?.cancel()
        service.activities.retryTasks[activityId] = Task { [weak service] in
            try? await AppClock.sleep(until: ContinuousClock.now + delay)
            if Task.isCancelled { return }
            guard let service else { return }
            await retry(registration, on: service)
        }
    }

    private static func retry(
        _ registration: LiveActivityUpdateTokenRegistration, on service: isolated PushRegistrationService
    ) async {
        guard service.activities.isPending(registration) else { return }
        await perform(registration, on: service)
    }
}
#endif
