#if os(iOS)
import Foundation

/// A minimal FIFO async mutex: at most one `withLock`/`acquire`-`release` section runs at a
/// time, and queued callers are granted the lock in the exact order they asked for it.
///
/// `LiveMailClient` uses one of these to serialize its whole `run` body — including the
/// liveness probe/reconnect — against every other `run` call. Plain actor isolation on its own
/// does not do this: it only excludes *synchronous* execution, not the suspension points inside
/// an `async` body, so without a lock a second call's SELECT could land between a first call's
/// SELECT and the STORE/COPY/EXPUNGE it guards.
///
/// This type owns no other state and makes no assumption about what it's protecting, so it's
/// independently testable (mutual exclusion, strict FIFO order, and that a throwing body still
/// releases) without any IMAP/network dependency.
actor AsyncSerialLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    /// How many callers are queued behind the current holder. Exists for the FIFO test, which
    /// has to know that waiter *n* has actually enqueued before it spawns waiter *n+1* — the
    /// only alternative being a sleep between spawns, which is a guess about scheduling rather
    /// than a fact about this queue, and the reason that test used to flake.
    var waiterCount: Int { waiters.count }

    /// Acquires the lock, queuing FIFO behind whoever already holds it. Every caller must pair
    /// this with a later `release()` (in both the success and failure paths) — `withLock` below
    /// does that automatically and is the safer choice for callers that don't have a specific
    /// reason to hold the lock across more than one `await` expression.
    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    /// Hands the lock to the next queued waiter, in the exact order it was requested, or marks
    /// the lock free if no one is waiting.
    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }

    /// Runs `body` with exclusive access, queuing FIFO behind whoever already holds the lock.
    /// The lock is released whether `body` returns or throws.
    func withLock<T>(_ body: () async throws -> T) async throws -> T {
        await acquire()
        do {
            let result = try await body()
            release()
            return result
        } catch {
            release()
            throw error
        }
    }
}
#endif
