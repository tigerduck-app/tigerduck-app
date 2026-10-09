// One-at-a-time access to the real, process-wide `Defaults` keys tests can reach no other way.
// `.serialized` orders one suite only, so every test touching them, save and restore included,
// runs in `withExclusiveRealDefaults`, never nested. See docs/decisions/0020-real-defaults-gate.md.
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
        // Resumed by `release()`, which hands the gate straight over
        // rather than clearing `isHeld` — so there is no window for a
        // third caller to take it in between, and no need to re-check.
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

/// Runs `body` with exclusive use of the real `Defaults` keys the gated tests share: push and
/// sync preferences, notification settings, the tab-bar migration keys and the update-check stamps.
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
