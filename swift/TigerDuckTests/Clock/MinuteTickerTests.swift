import Foundation
import Testing
@testable import TigerDuck

/// `tick` redraws the whole Class Table, so it moves when the minute does and not on every
/// 5-second check inside one.
@MainActor
struct MinuteTickerTests {
    /// A clock the test moves by hand.
    private final class TestClock {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }
    }

    @Test func movesOnlyWhenTheMinuteChanges() {
        // On a minute boundary: 5 and 55 seconds on stay in its minute, 60 starts the next.
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        // An hour between timer fires keeps the real timer out of the test.
        let ticker = MinuteTicker(interval: 3600, now: { clock.now })

        clock.now += 5
        ticker.advanceIfMinuteChanged()
        clock.now += 50
        ticker.advanceIfMinuteChanged()
        #expect(ticker.tick == 0)

        clock.now += 5
        ticker.advanceIfMinuteChanged()
        #expect(ticker.tick == 1)

        clock.now += 30
        ticker.advanceIfMinuteChanged()
        #expect(ticker.tick == 1)
    }

    @Test func movesOnceForAJumpOfSeveralMinutes() {
        // A debug clock override or a return from the background skips minutes.
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ticker = MinuteTicker(interval: 3600, now: { clock.now })

        clock.now += 600
        ticker.advanceIfMinuteChanged()
        ticker.advanceIfMinuteChanged()

        #expect(ticker.tick == 1)
    }
}
