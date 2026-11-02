import Foundation
import Testing
@testable import TigerDuck

/// A waiter that is never resumed hangs rather than fails, hence the limit. In CI, where every
/// suite runs at once, these main-actor tests have waited over a minute for their turn.
@MainActor
@Suite(.timeLimit(.minutes(5)))
struct StateSignalTests {
    @Test
    func aValueThatAlreadyPassesReturnsAtOnce() async {
        let signal = StateSignal(true)
        #expect(await signal.wait(until: { $0 }) == .ready)
        #expect(signal.waiterCount == 0)
    }

    @Test
    func aWaiterResumesOnTheChangeThatPassesItsTest() async throws {
        let signal = StateSignal(0)
        let waiter = Task { await signal.wait(until: { $0 >= 2 }) }
        try await waitUntil { signal.waiterCount == 1 }

        signal.value = 1
        #expect(signal.waiterCount == 1)
        signal.value = 2
        #expect(signal.waiterCount == 0)
        #expect(await waiter.value == .ready)
    }

    @Test
    func onlyTheWaitersAChangePassesResume() async throws {
        let signal = StateSignal("idle")
        let loading = Task { await signal.wait(until: { $0 == "loading" }) }
        let done = Task { await signal.wait(until: { $0 == "done" }) }
        try await waitUntil { signal.waiterCount == 2 }

        signal.value = "loading"
        #expect(await loading.value == .ready)
        #expect(signal.waiterCount == 1)
        signal.value = "done"
        #expect(await done.value == .ready)
    }

    @Test
    func theDeadlineEndsTheWaitTimedOut() async {
        let signal = StateSignal(false)
        let start = ContinuousClock.now
        let passed = await signal.wait(until: { $0 }, deadline: start + .milliseconds(50))
        #expect(passed == .timedOut)
        #expect(ContinuousClock.now >= start + .milliseconds(50))
        #expect(signal.waiterCount == 0)
    }

    @Test
    func aChangeBeforeTheDeadlineEndsTheWaitReady() async throws {
        let signal = StateSignal(false)
        let waiter = Task { await signal.wait(until: { $0 }, deadline: ContinuousClock.now + .seconds(60)) }
        try await waitUntil { signal.waiterCount == 1 }

        signal.value = true
        #expect(await waiter.value == .ready)
    }

    @Test
    func cancellingTheTaskEndsTheWaitCancelled() async throws {
        let signal = StateSignal(false)
        let waiter = Task { await signal.wait(until: { $0 }) }
        try await waitUntil { signal.waiterCount == 1 }

        waiter.cancel()
        #expect(await waiter.value == .cancelled)
        #expect(signal.waiterCount == 0)
    }
}
