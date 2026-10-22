import Foundation

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
