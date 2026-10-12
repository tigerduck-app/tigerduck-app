import SwiftUI

/// How long each kind of a course's Moodle data counts as fresh. A screen showing it fetches it
/// again once it is older: when the screen appears, when the app comes back to the foreground,
/// and on its own while the screen stays up. A pull always fetches.
nonisolated enum MoodleRefreshInterval {
    static let forums: TimeInterval = 5 * 60
    static let announcements: TimeInterval = 5 * 60
    static let materials: TimeInterval = 5 * 60
    static let grades: TimeInterval = 5 * 60
    static let members: TimeInterval = 30 * 60
}

/// Keeps one screen's data fresh while it runs: a refresh as soon as the data is older than
/// `ttl`, then another each time it ages past `ttl` again. A failed refresh waits a full `ttl`
/// before the next try, and a refresh from elsewhere, such as a pull, pushes the next one back.
@MainActor
final class MoodleRefreshTimer {
    let ttl: TimeInterval
    private let now: () -> Date
    private let sleep: @Sendable (Duration) async -> Void
    /// `nonisolated(unsafe)` so `deinit` can cancel it; everything else reaches it on the main actor.
    private nonisolated(unsafe) var loop: Task<Void, Never>?

    /// `now` is the real clock, not `AppClock`: the age of fetched data is real time.
    init(
        ttl: TimeInterval,
        now: @escaping () -> Date = { Date() },
        sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.ttl = ttl
        self.now = now
        self.sleep = sleep
    }

    /// The loop holds the screen's refresh, not this timer, so it would outlive a timer dropped
    /// without a `stop()`.
    deinit {
        loop?.cancel()
    }

    var isRunning: Bool { loop != nil }

    /// `fetchedAt` is read before every wait, so the timer follows refreshes it did not start.
    /// Nil means nothing is fetched yet, which is due at once.
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

    /// Seconds until the next refresh, 0 when it is due. Data stamped ahead of the clock, left by
    /// a clock set back, is due.
    nonisolated static func wait(fetchedAt: Date?, lastTry: Date?, ttl: TimeInterval, now: Date) -> TimeInterval {
        guard let last = [fetchedAt, lastTry].compactMap(\.self).max() else { return 0 }
        let age = now.timeIntervalSince(last)
        guard age >= 0 else { return 0 }
        return max(0, ttl - age)
    }
}

extension View {
    /// Refreshes the screen's data through `refresh` whenever it is older than `ttl`, while the
    /// screen is on display and the app is in the foreground.
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
