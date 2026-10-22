#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

/// Every test here can fail by hanging rather than by producing a wrong value — a lock that
/// stops handing the queue on leaves its waiters parked for ever — and Swift Testing applies no
/// default limit, so each one carries its own `.timeLimit`.
struct AsyncSerialLockTests {
    @Test(.timeLimit(.minutes(1)))
    func neverInterleavesTwoBodies() async throws {
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
        #expect(events == ["A-start", "A-end", "B-start", "B-end"] || events == ["B-start", "B-end", "A-start", "A-end"])
    }

    @Test(.timeLimit(.minutes(1)))
    func grantsStrictFIFOOrder() async throws {
        let lock = AsyncSerialLock()
        let recorder = LockOrderRecorder()

        await lock.acquire()

        // Spawn each waiter only once the previous one has enqueued, as `waiterCount` reports,
        // not after a sleep: a `Task {}` reaches `acquire()` in no fixed time, so a stagger could
        // queue B before A and fail a correct lock.
        var tasks: [Task<Void, Never>] = []
        for name in ["A", "B", "C"] {
            tasks.append(Task {
                await lock.acquire()
                await recorder.record(name)
                await lock.release()
            })
            while await lock.waiterCount < tasks.count { await Task.yield() }
        }

        await lock.release()

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

        var ranAfterThrow = false
        try await lock.withLock { ranAfterThrow = true }
        #expect(ranAfterThrow)
    }
}

private actor LockOrderRecorder {
    private(set) var events: [String] = []
    func record(_ event: String) { events.append(event) }
}
#endif
