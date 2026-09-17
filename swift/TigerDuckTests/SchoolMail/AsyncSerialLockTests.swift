#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

struct AsyncSerialLockTests {
    @Test func neverInterleavesTwoBodies() async throws {
        let lock = AsyncSerialLock()
        let recorder = LockOrderRecorder()

        async let first: Void = {
            try? await lock.withLock {
                await recorder.record("A-start")
                await Task.yield()
                await recorder.record("A-end")
            }
        }()
        async let second: Void = {
            try? await lock.withLock {
                await recorder.record("B-start")
                await Task.yield()
                await recorder.record("B-end")
            }
        }()
        _ = await (first, second)

        let events = await recorder.events
        // Whichever body wins the race runs to completion before the other one starts — the
        // "start" that lost must never appear before the winner's "end".
        #expect(events == ["A-start", "A-end", "B-start", "B-end"] || events == ["B-start", "B-end", "A-start", "A-end"])
    }

    @Test func grantsStrictFIFOOrder() async throws {
        let lock = AsyncSerialLock()
        let recorder = LockOrderRecorder()

        // Hold the lock in this task first, like an in-flight command, so every waiter below
        // queues behind it.
        await lock.acquire()

        // Each waiter is spawned only once the previous one has actually enqueued, which
        // `waiterCount` reports as a fact instead of a sleep guessing at it. A `Task {}` is not
        // guaranteed to reach its `acquire()` inside any fixed number of milliseconds, so the
        // old 10 ms staggers could put B in the queue before A and fail a correct lock.
        var tasks: [Task<Void, Never>] = []
        for name in ["A", "B", "C"] {
            tasks.append(Task {
                await lock.acquire()
                await recorder.record(name)
                await lock.release()
            })
            while await lock.waiterCount < tasks.count { await Task.yield() }
        }

        await lock.release() // let the queue start draining

        for task in tasks { await task.value }
        let events = await recorder.events
        #expect(events == ["A", "B", "C"])
    }

    /// `.timeLimit` because the failure mode this covers is a **hang**, not a wrong value: a
    /// `withLock` that stopped releasing on the error path would leave the second `withLock`
    /// below waiting forever, and Swift Testing applies no default limit.
    @Test(.timeLimit(.minutes(1)))
    func aThrowingBodyStillReleasesTheLock() async throws {
        let lock = AsyncSerialLock()
        struct TestError: Error {}

        await #expect(throws: TestError.self) {
            try await lock.withLock { throw TestError() }
        }

        // If the throw above hadn't released the lock, this would hang until the test times out.
        var ranAfterThrow = false
        try await lock.withLock { ranAfterThrow = true }
        #expect(ranAfterThrow)
    }
}

/// Collects events from concurrent tasks without a data race — used only to assert ordering in
/// the tests above.
private actor LockOrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
#endif
