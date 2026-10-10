#if os(iOS)
import Foundation

/// A minimal FIFO async mutex: at most one `withLock` or `acquire`/`release` section runs at a
/// time, and queued callers get the lock in the order they asked for it. It knows nothing of
/// IMAP, so tests cover exclusion, FIFO order and release after a throw without a network.
///
/// `LiveMailClient` serializes each whole `run` body, liveness probe and reconnect included,
/// with one. Actor isolation alone does not: it excludes only synchronous execution, so a
/// second call's SELECT could run at a suspension point between a first call's SELECT and the
/// STORE/COPY/EXPUNGE it guards.
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
