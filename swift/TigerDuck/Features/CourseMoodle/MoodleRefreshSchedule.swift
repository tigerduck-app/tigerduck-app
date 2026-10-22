import SwiftUI

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
    /// `nonisolated(unsafe)` so `deinit` can cancel it; everything else reaches it on the main actor.
    private nonisolated(unsafe) var loop: Task<Void, Never>?

    init(
        ttl: TimeInterval,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.ttl = ttl
        self.now = now
        self.sleep = sleep
    }

    deinit {
        loop?.cancel()
    }

    var isRunning: Bool { loop != nil }

    func start(fetchedAt: @escaping () -> Date?, refresh: @escaping () async -> Void) {
        loop?.cancel()
        loop = Task { [ttl, now, sleep] in
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
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    nonisolated static func wait(fetchedAt: Date?, lastTry: Date?, ttl: TimeInterval, now: Date) -> TimeInterval {
        let fetched = fetchedAt.flatMap { $0 <= now ? $0 : nil }
        guard let last = [fetched, lastTry].compactMap(\.self).max() else { return 0 }
        return min(ttl, max(0, ttl - now.timeIntervalSince(last)))
    }
}

extension View {
    func moodleAutoRefresh(
        every ttl: TimeInterval,
        fetchedAt: @escaping () -> Date?,
        refresh: @escaping () async -> Void
    ) -> some View {
        modifier(MoodleAutoRefreshModifier(ttl: ttl, fetchedAt: fetchedAt, refresh: refresh))
    }
}

private struct MoodleAutoRefreshModifier: ViewModifier {
    let ttl: TimeInterval
    let fetchedAt: () -> Date?
    let refresh: () async -> Void

    @Environment(\.scenePhase) private var scenePhase
    @State private var timer: MoodleRefreshTimer?
    @State private var isOnScreen = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isOnScreen = true
                update()
            }
            .onDisappear {
                isOnScreen = false
                update()
            }
            .onChange(of: scenePhase) { update() }
    }

    private func update() {
        let timer = timer ?? MoodleRefreshTimer(ttl: ttl)
        self.timer = timer
        guard isOnScreen, scenePhase == .active else {
            timer.stop()
            return
        }
        if !timer.isRunning { timer.start(fetchedAt: fetchedAt, refresh: refresh) }
    }
}
