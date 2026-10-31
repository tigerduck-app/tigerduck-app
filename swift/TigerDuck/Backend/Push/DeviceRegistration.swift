import Foundation
import os

/// The device register: a debounced attempt once a token arrives, its retries, and the passive
/// register a Mac sends without a token. It runs isolated to the `PushRegistrationService` it is
/// given, as the service's own did, so each step reads the service as it is after each await.
nonisolated enum DeviceRegistration {
    static func registerIfReady(on service: isolated PushRegistrationService) {
        #if os(iOS)
        guard !service.tokens.isEmpty else { return }

        service.lastAttempt?.cancel()
        let sleep = service.debounceSleep
        service.lastAttempt = Task { [weak service] in
            await sleep(.milliseconds(250))
            if Task.isCancelled { return }
            guard let service else { return }
            await perform(on: service)
        }
        #endif
    }

    static func perform(on service: isolated PushRegistrationService) async {
        let requests = service.requests
        let pushTokens = requests.pushTokens(device: service.tokens.device, pts: service.tokens.pts)
        guard !pushTokens.isEmpty else { return }
        service.running.inFlight += 1
        defer {
            service.running.inFlight -= 1
            service.running.releaseIfIdle()
        }
        await requests.announce(deviceToken: service.tokens.device)
        do {
            try await requests.register(pushTokens)
            service.retry.cancel()
            service.retry.attempts = 0
            noteSuccess(on: service)
            #if os(iOS)
            await ActivityTokenRegistration.flushPending(on: service)
            #endif
            await service.resendSyncPreferencesIfPending()
        } catch is CancellationError {
        } catch let error as NSError where error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled {
        } catch {
            service.logger.error("register failed: \(error.localizedDescription, privacy: .private)")
            service.status.note(error)
            if service.retry.againIfRunningFails {
                service.retry.againIfRunningFails = false
                registerIfReady(on: service)
            } else {
                scheduleRetry(on: service)
            }
        }
    }

    private static func scheduleRetry(on service: isolated PushRegistrationService) {
        service.retry.attempts += 1
        let attempts = service.retry.attempts
        guard attempts < PushRegistrationService.DeviceRetry.maxAttempts else {
            service.logger.error("giving up on device register attempts=\(attempts, privacy: .public)")
            return
        }
        let delay = PushRegistrationService.retryDelay(attempt: attempts)
        let sleep = service.retrySleep
        service.retry.task?.cancel()
        service.retry.task = Task { [weak service] in
            await sleep(.seconds(delay))
            if Task.isCancelled { return }
            guard let service else { return }
            await perform(on: service)
        }
    }

    #if os(macOS)
    static func registerPassive(on service: isolated PushRegistrationService) async {
        service.running.passive += 1
        defer {
            service.running.passive -= 1
            service.running.releaseIfIdle()
        }
        do {
            try await service.requests.registerPassive()
            noteSuccess(on: service)
            await service.resendSyncPreferencesIfPending()
        } catch {
            service.logger.error("passive device register failed: \(error.localizedDescription, privacy: .private)")
            service.status.note(error)
        }
    }
    #endif

    private static func noteSuccess(on service: isolated PushRegistrationService) {
        service.status.noteSuccess()
        service.retry.againIfRunningFails = false
    }
}
