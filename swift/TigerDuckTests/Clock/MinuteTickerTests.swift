import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct MinuteTickerTests {
    private final class TestClock {
        var now: Date

        init(_ now: Date) {
            self.now = now
        }
    }

    @Test func movesOnlyWhenTheMinuteChanges() {
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
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
        let clock = TestClock(Date(timeIntervalSince1970: 1_800_000_000))
        let ticker = MinuteTicker(interval: 3600, now: { clock.now })

        clock.now += 600
        ticker.advanceIfMinuteChanged()
        ticker.advanceIfMinuteChanged()

        #expect(ticker.tick == 1)
    }
}
