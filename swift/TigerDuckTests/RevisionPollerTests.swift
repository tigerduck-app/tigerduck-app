import Foundation
import Testing
@testable import TigerDuck

struct RevisionPollScheduleTests {
    private static let start = Date(timeIntervalSince1970: 1_000_000)

    private static func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    @Test("A minute after a return it polls every 10 seconds")
    func activeWindowKeepsTenSeconds() {
        var schedule = RevisionPollSchedule(now: Self.start)
        #expect(schedule.delayAfterAnswer(at: Self.at(10)) == 10)
        #expect(schedule.delayAfterAnswer(at: Self.at(59)) == 10)
    }

    @Test("Then each quiet answer doubles the wait, up to the cap")
    func quietAnswersDoubleUpToTheCap() {
        var schedule = RevisionPollSchedule(now: Self.start)
        let waits = [61, 81, 121, 181, 241].map { schedule.delayAfterAnswer(at: Self.at(TimeInterval($0))) }
        #expect(waits == [20, 40, min(80, RevisionPollSchedule.idleCap), RevisionPollSchedule.idleCap,
                          RevisionPollSchedule.idleCap])
    }

    @Test("A change or a local edit brings back the 10-second cadence")
    func activityRestoresTheActiveCadence() {
        var schedule = RevisionPollSchedule(now: Self.start)
        _ = schedule.delayAfterAnswer(at: Self.at(61))
        _ = schedule.delayAfterAnswer(at: Self.at(81))
        schedule.noteActivity(at: Self.at(100))
        #expect(schedule.delayAfterAnswer(at: Self.at(110)) == 10)
        #expect(schedule.delayAfterAnswer(at: Self.at(161)) == 20)
    }

    @Test("Failures back off exponentially up to 300 seconds")
    func failuresBackOffToTheCap() {
        var schedule = RevisionPollSchedule(now: Self.start)
        let waits = (0..<6).map { _ in schedule.delayAfterFailure(at: Self.at(5), jitter: 1) }
        #expect(waits == [20, 40, 80, 160, 300, 300])
    }

    @Test("A failure never waits less than the schedule it interrupts")
    func failuresStartFromTheIdleWait() {
        var schedule = RevisionPollSchedule(now: Self.start)
        _ = schedule.delayAfterAnswer(at: Self.at(61))
        _ = schedule.delayAfterAnswer(at: Self.at(81))
        #expect(schedule.delayAfterFailure(at: Self.at(121), jitter: 0) == 40)
    }

    @Test("Jitter spreads a failure's wait over the upper half of its backoff")
    func jitterSpreadsTheUpperHalf() {
        var low = RevisionPollSchedule(now: Self.start)
        var high = RevisionPollSchedule(now: Self.start)
        #expect(low.delayAfterFailure(at: Self.at(5), jitter: 0) == 10)
        #expect(high.delayAfterFailure(at: Self.at(5), jitter: 1) == 20)
    }

    @Test("An answer after failures returns to the schedule")
    func answerClearsTheBackoff() {
        var schedule = RevisionPollSchedule(now: Self.start)
        _ = schedule.delayAfterFailure(at: Self.at(5), jitter: 1)
        _ = schedule.delayAfterFailure(at: Self.at(25), jitter: 1)
        #expect(schedule.delayAfterAnswer(at: Self.at(30)) == 10)
        #expect(schedule.delayAfterFailure(at: Self.at(40), jitter: 1) == 20)
    }
}

@MainActor
struct RevisionPollerTests {
    @MainActor
    private final class ScriptedPoll {
        var outcomes: [RevisionPollOutcome] = []
        var holds = false
        private(set) var calls = 0
        private var parked: CheckedContinuation<Void, Never>?

        func run() async -> RevisionPollOutcome {
            calls += 1
            if holds {
                holds = false
                await withCheckedContinuation { parked = $0 }
            }
            return outcomes.isEmpty ? .unchanged : outcomes.removeFirst()
        }

        var isParked: Bool { parked != nil }

        func release() {
            parked?.resume()
            parked = nil
        }
    }

    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
    }

    private static func makePoller(
        _ poll: ScriptedPoll,
        sleeper: ManualSleeper,
        clock: TestClock = TestClock(),
        relogin: @escaping @MainActor () async -> Bool = { false }
    ) -> RevisionPoller {
        let poller = RevisionPoller(sleep: { await sleeper.sleep(for: $0) }, now: { clock.now }, jitter: { 1 })
        poller.poll = { await poll.run() }
        poller.relogin = relogin
        return poller
    }

    @Test("A return polls at once, then waits 10 seconds")
    func returnPollsAtOnce() async throws {
        let poll = ScriptedPoll()
        let sleeper = ManualSleeper()
        let poller = Self.makePoller(poll, sleeper: sleeper)

        poller.start(pollNow: true)

        try await waitUntil { poll.calls == 1 }
        try await sleeper.waitUntilArmed()
        #expect(await sleeper.requestedDurations == [.seconds(10)])
    }

    @Test("Launch waits for its first poll; its own sync has just pulled")
    func launchWaitsForItsFirstPoll() async throws {
        let poll = ScriptedPoll()
        let sleeper = ManualSleeper()
        let poller = Self.makePoller(poll, sleeper: sleeper)

        poller.start(pollNow: false)
        try await sleeper.waitUntilArmed()
        #expect(poll.calls == 0)

        await sleeper.fire()
        try await waitUntil { poll.calls == 1 }
    }

    @Test("Returns poll at most once per 10 seconds")
    func quickReturnsWaitOutTheCadence() async throws {
        let poll = ScriptedPoll()
        let sleeper = ManualSleeper()
        let clock = TestClock()
        let poller = Self.makePoller(poll, sleeper: sleeper, clock: clock)

        poller.start(pollNow: true)
        try await sleeper.waitUntilArmed()
        clock.now += 4
        poller.start(pollNow: true)
        try await sleeper.waitUntilArmed(atLeast: 2)

        #expect(poll.calls == 1)
        #expect(await sleeper.requestedDurations == [.seconds(10), .seconds(6)])
    }

    @Test("A return while a poll is in flight sends no second request")
    func noSecondRequestWhileOneIsInFlight() async throws {
        let poll = ScriptedPoll()
        poll.holds = true
        let sleeper = ManualSleeper()
        let poller = Self.makePoller(poll, sleeper: sleeper)

        poller.start(pollNow: true)
        try await waitUntil { poll.isParked }
        poller.start(pollNow: true)
        poller.noteActivity()
        #expect(poll.calls == 1)

        poll.release()
        try await sleeper.waitUntilArmed()
        try await waitUntil { !poller.isPolling }
        #expect(poll.calls == 1)
        #expect(await sleeper.armedCount == 1)
    }

    @Test("A stop lets the poll in flight finish and arms nothing after it")
    func stopDuringAPollArmsNothing() async throws {
        let poll = ScriptedPoll()
        poll.holds = true
        let sleeper = ManualSleeper()
        let poller = Self.makePoller(poll, sleeper: sleeper)

        poller.start(pollNow: true)
        try await waitUntil { poll.isParked }
        poller.stop()
        poll.release()

        try await waitUntil { !poller.isPolling }
        #expect(await sleeper.armedCount == 0)
    }

    @Test("A 401 gets one relogin, and a second 401 stops polling until the next return")
    func secondUnauthorizedSuspendsUntilReturn() async throws {
        let poll = ScriptedPoll()
        poll.outcomes = [.unauthorized, .unauthorized]
        let sleeper = ManualSleeper()
        let clock = TestClock()
        var relogins = 0
        let poller = Self.makePoller(poll, sleeper: sleeper, clock: clock) {
            relogins += 1
            return true
        }

        poller.start(pollNow: true)
        try await sleeper.waitUntilArmed()
        #expect(relogins == 1)
        await sleeper.fire()
        try await waitUntil { poller.isSuspended && !poller.isPolling }
        #expect(poll.calls == 2)
        #expect(relogins == 1)
        #expect(await sleeper.armedCount == 1)

        poller.noteActivity()
        #expect(await sleeper.armedCount == 1)

        clock.now += RevisionPollSchedule.activeInterval
        poller.start(pollNow: true)
        try await waitUntil { poll.calls == 3 }
    }

    @Test("A failed relogin stops polling until the next return")
    func failedReloginSuspendsUntilReturn() async throws {
        let poll = ScriptedPoll()
        poll.outcomes = [.unauthorized]
        let sleeper = ManualSleeper()
        let poller = Self.makePoller(poll, sleeper: sleeper) { false }

        poller.start(pollNow: true)
        try await waitUntil { poller.isSuspended && !poller.isPolling }
        #expect(await sleeper.armedCount == 0)
    }

    @Test("Failed polls wait longer each time")
    func failedPollsBackOff() async throws {
        let poll = ScriptedPoll()
        poll.outcomes = [.failed, .failed, .failed]
        let sleeper = ManualSleeper()
        let poller = Self.makePoller(poll, sleeper: sleeper)

        poller.start(pollNow: true)
        for armed in 1...3 {
            try await sleeper.waitUntilArmed(atLeast: armed)
            await sleeper.fire()
        }
        try await sleeper.waitUntilArmed(atLeast: 4)
        #expect(await sleeper.requestedDurations == [.seconds(20), .seconds(40), .seconds(80), .seconds(10)])
    }
}
