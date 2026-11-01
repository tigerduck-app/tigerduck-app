import Foundation
import os

nonisolated enum MoodleRefreshInterval {
    static let forums: TimeInterval = 5 * 60
    static let announcements: TimeInterval = 5 * 60
    static let materials: TimeInterval = 5 * 60
    static let grades: TimeInterval = 5 * 60
    static let summary: TimeInterval = 5 * 60
    static let members: TimeInterval = 30 * 60
}

@MainActor
final class MoodleRefreshTimer {
    let ttl: TimeInterval
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    private let loop = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    init(
        ttl: TimeInterval,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await AppClock.sleep(until: ContinuousClock.now + $0) }
    ) {
        self.ttl = ttl
        self.now = now
        self.sleep = sleep
    }

    deinit {
        loop.withLock { $0?.cancel() }
    }

    var isRunning: Bool { loop.withLock { $0 != nil } }

    func start(fetchedAt: @escaping () -> Date?, refresh: @escaping () async -> Void) {
        let task = Task { [ttl, now, sleep] in
            var lastTry: Date?
            while !Task.isCancelled {
                let wait = Self.wait(fetchedAt: fetchedAt(), lastTry: lastTry, ttl: ttl, now: now())
                if wait > 0 {
                    await sleep(.seconds(wait))
                } else {
                    lastTry = now()
                    await refresh()
                }
            }
        }
        loop.withLock { running in
            running?.cancel()
            running = task
        }
    }

    func stop() {
        loop.withLock { running in
            running?.cancel()
            running = nil
        }
    }

    nonisolated static func wait(fetchedAt: Date?, lastTry: Date?, ttl: TimeInterval, now: Date) -> TimeInterval {
        let fetched = fetchedAt.flatMap { $0 <= now ? $0 : nil }
        guard let last = [fetched, lastTry].compactMap(\.self).max() else { return 0 }
        return min(ttl, max(0, ttl - now.timeIntervalSince(last)))
    }
}
