import ActivityKit
import Foundation

@MainActor
final class LiveActivityTasks {
    private var endTimers: [String: Task<Void, Never>] = [:]
    private var tokenWatches: [String: Task<Void, Never>] = [:]
    var tokenHandler: (@Sendable (LiveActivityUpdateTokenRegistration) async -> Void)?
    var isAvailable: () -> Bool = { true }

    static let endGrace: TimeInterval = 1

    deinit {
        for task in endTimers.values {
            task.cancel()
        }
        for task in tokenWatches.values {
            task.cancel()
        }
    }

    func scheduleEnd(
        for activityId: String,
        snapshot: LiveActivitySnapshot,
        expire: @escaping @MainActor (_ target: Date) async -> Void
    ) {
        endTimers[activityId]?.cancel()

        guard let target = snapshot.countdownTarget else {
            endTimers[activityId] = nil
            return
        }

        let realTarget = AppClock.realTime(forApp: target)
        let delay = max(0, realTarget.timeIntervalSinceNow) + Self.endGrace
        endTimers[activityId] = Task { @MainActor in
            try? await AppClock.sleep(until: ContinuousClock.now + .seconds(delay))
            guard !Task.isCancelled else { return }
            await expire(target)
        }
    }

    func endTimerFired(for activityId: String) {
        endTimers[activityId] = nil
    }

    func cancel(_ activityId: String) {
        endTimers[activityId]?.cancel()
        endTimers[activityId] = nil
        cancelTokenWatch(activityId)
    }

    func cancelTokenWatch(_ activityId: String) {
        tokenWatches[activityId]?.cancel()
        tokenWatches[activityId] = nil
    }

    func cancelAll(except retainedIds: Set<String> = []) {
        for activityId in Array(endTimers.keys) where !retainedIds.contains(activityId) {
            endTimers[activityId]?.cancel()
            endTimers[activityId] = nil
        }
        for activityId in Array(tokenWatches.keys) where !retainedIds.contains(activityId) {
            tokenWatches[activityId]?.cancel()
            tokenWatches[activityId] = nil
        }
    }

    func watchToken(of activity: Activity<TigerDuckActivityAttributes>) {
        let activityId = activity.attributes.activityId
        guard tokenWatches[activityId] == nil else { return }
        tokenWatches[activityId] = Task { @MainActor [weak self] in
            await self?.registerCurrentToken(of: activity)
            for await tokenData in activity.pushTokenUpdates {
                guard !Task.isCancelled else { return }
                await self?.register(
                    activityId: activityId,
                    tokenData: tokenData,
                    snapshot: activity.content.state.snapshot
                )
            }
            guard !Task.isCancelled else { return }
            self?.tokenWatches[activityId] = nil
        }
    }

    private func registerCurrentToken(of activity: Activity<TigerDuckActivityAttributes>) async {
        guard let tokenData = activity.pushToken else { return }
        await register(
            activityId: activity.attributes.activityId,
            tokenData: tokenData,
            snapshot: activity.content.state.snapshot
        )
    }

    private func register(
        activityId: String,
        tokenData: Data,
        snapshot: LiveActivitySnapshot
    ) async {
        guard let tokenHandler, isAvailable() else { return }
        let tokenHex = tokenData.hexEncodedString()
        await tokenHandler(
            LiveActivityUpdateTokenRegistration(
                activityId: activityId,
                updateTokenHex: tokenHex,
                snapshot: snapshot
            )
        )
    }
}
