import Foundation

extension PushRegistrationService {
    nonisolated struct HeldTokens {
        var device: String?
        var pts: String?

        var isEmpty: Bool { device == nil && pts == nil }
    }

    nonisolated struct Status {
        var lastError: String?
        var foundNoSession = false
        var registeredAt: Date?

        mutating func noteSuccess() {
            registeredAt = Date()
            lastError = nil
            foundNoSession = false
        }

        mutating func note(_ error: Error) {
            lastError = "register: \(error.localizedDescription)"
            foundNoSession = if case PushAPIError.notSignedIn = error { true } else { false }
        }
    }

    nonisolated struct PatchChains {
        var optOut = RequestChain()
        var bulletin = RequestChain()
        var syncPreferences = RequestChain()
    }

    nonisolated struct DeviceRetry {
        static let maxAttempts = 4
        var task: Task<Void, Never>?
        var attempts = 0
        var againIfRunningFails = false

        mutating func cancel() {
            task?.cancel()
            task = nil
        }
    }

    nonisolated struct RunningRegistrations {
        var inFlight = 0
        #if os(macOS)
        var passive = 0
        #endif
        var cloudSyncPatchesWaiting: [CheckedContinuation<Void, Never>] = []

        var isRegistering: Bool {
            #if os(macOS)
            inFlight > 0 || passive > 0
            #else
            inFlight > 0
            #endif
        }

        mutating func releaseIfIdle() {
            guard !isRegistering else { return }
            let waiting = cloudSyncPatchesWaiting
            cloudSyncPatchesWaiting = []
            for patch in waiting { patch.resume() }
        }
    }

    #if os(iOS)
    nonisolated struct ActivityRegistrations {
        static let maxNotFoundAttempts = 2
        static let maxAttempts = 4
        var pending: [String: LiveActivityUpdateTokenRegistration] = [:]
        var notFoundAttempts: [String: Int] = [:]
        var retryTasks: [String: Task<Void, Never>] = [:]
        var attempts: [String: Int] = [:]

        func isPending(_ registration: LiveActivityUpdateTokenRegistration) -> Bool {
            pending[registration.activityId]?.updateTokenHex == registration.updateTokenHex
        }

        mutating func landed(_ registration: LiveActivityUpdateTokenRegistration) {
            let activityId = registration.activityId
            if isPending(registration) {
                pending[activityId] = nil
            }
            retryTasks[activityId]?.cancel()
            retryTasks[activityId] = nil
            attempts[activityId] = nil
            notFoundAttempts[activityId] = nil
        }

        mutating func countNotFound(_ activityId: String) -> Int {
            let attempts = (notFoundAttempts[activityId] ?? 0) + 1
            notFoundAttempts[activityId] = attempts
            return attempts
        }

        mutating func countAttempt(_ activityId: String) -> Int {
            let attempt = (attempts[activityId] ?? 0) + 1
            attempts[activityId] = attempt
            return attempt
        }

        mutating func giveUp(_ activityId: String) {
            pending[activityId] = nil
            retryTasks[activityId]?.cancel()
            retryTasks[activityId] = nil
            attempts[activityId] = nil
        }

        mutating func removeAll() {
            pending.removeAll()
            for task in retryTasks.values {
                task.cancel()
            }
            retryTasks.removeAll()
            attempts.removeAll()
            notFoundAttempts.removeAll()
        }
    }
    #endif

    static func retryDelay(attempt: Int) -> Duration {
        .seconds(min(30 * pow(3.0, Double(attempt - 1)), 600))
    }
}
