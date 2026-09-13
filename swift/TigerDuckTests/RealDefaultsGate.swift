// One-at-a-time access to the app's real push-preference `Defaults` keys.
//
// `pushServerEnabled`, `bulletinPushEnabled` and `serverPushUserOptOut`
// have no `Defaults.suite` override (see `AppDefaults.swift`), and neither
// `BulletinPushOptOutMigration` nor `PushRegistrationService` takes them
// through a seam — the migration's whole job is those keys, and the
// register body and the bulletin PATCH read and write them directly. So the
// only way to observe either is to write the real, process-wide keys.
//
// `.serialized` is not enough on its own: it orders one suite's own tests
// and nothing else, while Swift Testing runs suites concurrently. The
// register tests hold a pinned value across a 250 ms debounce, which is
// plenty of room for a migration test to reset the same keys underneath
// them — observed as `rejectedBulletinPatchDoesNotPersist` failing
// `Defaults[.bulletinPushEnabled] == true` in one full-suite run and
// passing in the next.
//
// Every test that touches those three keys goes through
// `withExclusiveRealDefaults`, save and restore included, so only one of
// them is ever inside that window.
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

/// Runs `body` with exclusive use of the real push-preference keys.
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
