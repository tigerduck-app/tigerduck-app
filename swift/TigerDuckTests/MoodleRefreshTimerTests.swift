import Foundation
import os
import Testing
@testable import TigerDuck

/// `MoodleRefreshTimer` with a stand-in clock and `ManualSleeper` waits, so each refresh happens
/// when the test fires a wait and the test can check how long each wait was.
@MainActor
struct MoodleRefreshTimerTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)
    private static let ttl: TimeInterval = 300

    /// What the screen holds: when its data was fetched, and how often it was refreshed.
    private final class Screen {
        var fetchedAt: Date?
        var refreshes = 0
    }

    private static func timer(clock: OSAllocatedUnfairLock<Date>, sleeper: ManualSleeper) -> MoodleRefreshTimer {
        MoodleRefreshTimer(ttl: ttl, now: { clock.withLock { $0 } }, sleep: { await sleeper.sleep(for: $0) })
    }

    @Test("each kind of Moodle data has its own freshness, members the longest")
    func intervals() {
        #expect(MoodleRefreshInterval.forums == 300)
        #expect(MoodleRefreshInterval.announcements == 300)
        #expect(MoodleRefreshInterval.materials == 300)
        #expect(MoodleRefreshInterval.grades == 300)
        #expect(MoodleRefreshInterval.members == 1800)
    }

    @Test("the wait is what is left of the freshness, counted from the later of the fetch and the last try")
    func waitArithmetic() {
        let now = Self.start
        #expect(MoodleRefreshTimer.wait(fetchedAt: nil, lastTry: nil, ttl: 300, now: now) == 0)
        #expect(MoodleRefreshTimer.wait(fetchedAt: now - 60, lastTry: nil, ttl: 300, now: now) == 240)
        #expect(MoodleRefreshTimer.wait(fetchedAt: now - 300, lastTry: nil, ttl: 300, now: now) == 0)
        #expect(MoodleRefreshTimer.wait(fetchedAt: now - 900, lastTry: now - 10, ttl: 300, now: now) == 290)
        // A clock set back leaves the data stamped in the future; it is fetched again, but a try
        // just made still holds the next one back, and a try stamped ahead waits no more than the TTL.
        #expect(MoodleRefreshTimer.wait(fetchedAt: now + 60, lastTry: nil, ttl: 300, now: now) == 0)
        #expect(MoodleRefreshTimer.wait(fetchedAt: now + 60, lastTry: now - 10, ttl: 300, now: now) == 290)
        #expect(MoodleRefreshTimer.wait(fetchedAt: nil, lastTry: now + 60, ttl: 300, now: now) == 300)
    }

    @Test("data with no fetch yet is fetched at once, and fetched again each time it ages past its freshness")
    func refreshesOnATimer() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let sleeper = ManualSleeper()
        let screen = Screen()
        let timer = Self.timer(clock: clock, sleeper: sleeper)
        timer.start(fetchedAt: { screen.fetchedAt }) {
            screen.refreshes += 1
            screen.fetchedAt = clock.withLock { $0 }
        }

        try await waitUntil { screen.refreshes == 1 }
        try await sleeper.waitUntilArmed()
        #expect(await sleeper.requestedDurations == [.seconds(300)])

        clock.withLock { $0 += 300 }
        await sleeper.fire()
        try await waitUntil { screen.refreshes == 2 }
        try await sleeper.waitUntilArmed(atLeast: 2)
        #expect(await sleeper.requestedDurations == [.seconds(300), .seconds(300)])
        timer.stop()
    }

    @Test("fresh data waits out what is left of its freshness before the first refresh")
    func freshDataWaits() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let sleeper = ManualSleeper()
        let screen = Screen()
        screen.fetchedAt = Self.start - 60
        let timer = Self.timer(clock: clock, sleeper: sleeper)
        timer.start(fetchedAt: { screen.fetchedAt }) { screen.refreshes += 1 }

        try await sleeper.waitUntilArmed()
        #expect(await sleeper.requestedDurations == [.seconds(240)])
        #expect(screen.refreshes == 0)

        clock.withLock { $0 += 240 }
        await sleeper.fire()
        try await waitUntil { screen.refreshes == 1 }
        timer.stop()
    }

    @Test("a refresh that fetches nothing waits a full freshness before it tries again")
    func failedRefreshDoesNotSpin() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let sleeper = ManualSleeper()
        let screen = Screen()
        let timer = Self.timer(clock: clock, sleeper: sleeper)
        timer.start(fetchedAt: { screen.fetchedAt }) { screen.refreshes += 1 }

        try await sleeper.waitUntilArmed()
        #expect(screen.refreshes == 1)
        #expect(await sleeper.requestedDurations == [.seconds(300)])
        timer.stop()
    }

    @Test("a fetch made elsewhere during the wait, such as a pull, moves the next refresh back")
    func pullMovesTheNextRefresh() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let sleeper = ManualSleeper()
        let screen = Screen()
        screen.fetchedAt = Self.start
        let timer = Self.timer(clock: clock, sleeper: sleeper)
        timer.start(fetchedAt: { screen.fetchedAt }) { screen.refreshes += 1 }
        try await sleeper.waitUntilArmed()

        clock.withLock { $0 += 200 }
        screen.fetchedAt = clock.withLock { $0 }
        clock.withLock { $0 += 100 }
        await sleeper.fire()

        try await sleeper.waitUntilArmed(atLeast: 2)
        #expect(await sleeper.requestedDurations == [.seconds(300), .seconds(200)])
        #expect(screen.refreshes == 0)
        timer.stop()
    }

    @Test("a stopped timer refreshes no more, and starting it again checks at once")
    func stopAndRestart() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Self.start)
        let sleeper = ManualSleeper()
        let screen = Screen()
        screen.fetchedAt = Self.start
        let timer = Self.timer(clock: clock, sleeper: sleeper)
        timer.start(fetchedAt: { screen.fetchedAt }) { screen.refreshes += 1 }
        try await sleeper.waitUntilArmed()

        timer.stop()
        #expect(!timer.isRunning)
        clock.withLock { $0 += 400 }
        await sleeper.fire()
        try await Task.sleep(for: .milliseconds(50))
        #expect(screen.refreshes == 0)

        timer.start(fetchedAt: { screen.fetchedAt }) { screen.refreshes += 1 }
        try await waitUntil { screen.refreshes == 1 }
        timer.stop()
    }
}
