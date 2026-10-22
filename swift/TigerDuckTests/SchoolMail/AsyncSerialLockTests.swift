#if os(iOS)
import Foundation
import Testing
@testable import TigerDuck

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
