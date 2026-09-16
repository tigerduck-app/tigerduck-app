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

        let taskA = Task {
            await lock.acquire()
            await recorder.record("A")
            await lock.release()
        }
        // Stagger each spawn so every waiter has enqueued behind the held lock before the next
        // one is even created — this is what makes the arrival order (and so the expected FIFO
        // order) deterministic.
        try await Task.sleep(for: .milliseconds(10))
        let taskB = Task {
            await lock.acquire()
            await recorder.record("B")
            await lock.release()
        }
        try await Task.sleep(for: .milliseconds(10))
        let taskC = Task {
            await lock.acquire()
            await recorder.record("C")
            await lock.release()
        }
        try await Task.sleep(for: .milliseconds(10))

        await lock.release() // let the queue start draining

        _ = await (taskA.value, taskB.value, taskC.value)
        let events = await recorder.events
        #expect(events == ["A", "B", "C"])
    }

    @Test func aThrowingBodyStillReleasesTheLock() async throws {
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
