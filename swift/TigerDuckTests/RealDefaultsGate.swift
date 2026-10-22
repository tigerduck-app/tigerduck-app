import Foundation

/// Async mutual exclusion. An actor rather than a lock because callers hold
/// it across `await`s — a `NSLock` held over a suspension can be released
/// on a different thread than took it.
actor RealDefaultsGate {
    static let shared = RealDefaultsGate()

    private var isHeld = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        guard isHeld else {
            isHeld = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if waiting.isEmpty {
            isHeld = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}

func withExclusiveRealDefaults<T>(_ body: () async throws -> T) async rethrows -> T {
    await RealDefaultsGate.shared.acquire()
    do {
        let result = try await body()
        await RealDefaultsGate.shared.release()
        return result
    } catch {
        await RealDefaultsGate.shared.release()
        throw error
    }
}
