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

    var waiterCount: Int { waiters.count }

    func acquire() async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        guard !waiters.isEmpty else {
            isHeld = false
            return
        }
        waiters.removeFirst().resume()
    }

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
