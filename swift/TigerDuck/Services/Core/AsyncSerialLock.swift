import Foundation

/// A minimal FIFO async mutex: at most one `withLock` or `acquire`/`release` section runs at a
/// time, and callers get it in the order they asked, except that a `yielding` one waits behind
/// every other, even a later one. It knows nothing of IMAP, so tests run without a network.
///
/// `LiveMailClient` serializes each whole `run` body, liveness probe and reconnect included,
/// with one. Actor isolation alone does not: it excludes only synchronous execution, so a
/// second call's SELECT could run at a suspension point between a first call's SELECT and the
/// STORE/COPY/EXPUNGE it guards.
actor AsyncSerialLock {
    private var isHeld = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var yieldingWaiters: [CheckedContinuation<Void, Never>] = []

    init() {}

    var waiterCount: Int { waiters.count + yieldingWaiters.count }

    func acquire(yielding: Bool = false) async {
        if !isHeld {
            isHeld = true
            return
        }
        await withCheckedContinuation { continuation in
            if yielding {
                yieldingWaiters.append(continuation)
            } else {
                waiters.append(continuation)
            }
        }
    }

    func release() {
        if !waiters.isEmpty {
            waiters.removeFirst().resume()
        } else if !yieldingWaiters.isEmpty {
            yieldingWaiters.removeFirst().resume()
        } else {
            isHeld = false
        }
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
