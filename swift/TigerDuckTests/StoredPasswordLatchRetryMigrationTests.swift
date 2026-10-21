// Runs on the real keys, which are the migration's whole job, inside `withExclusiveRealDefaults`.
// Each key is restored as present or absent, as the migration reads an absent key as never set.
import Foundation
import Testing
@testable import TigerDuck

/// 2.6.2 and earlier stopped every automatic post of the stored password after one refusal, until
/// the user signed in again (https://github.com/tigerduck-app/tigerduck-app/issues/768).
@MainActor
@Suite(.serialized)
struct StoredPasswordLatchRetryMigrationTests {
    static let doneKey = "StoredPasswordLatchRetryMigration.v1.done"
    static let latchKey = "ntustStoredPasswordRejected"

    /// Runs `body` before the migration, with the old latch up when `latched` and no refusals, then
    /// puts back the migration's keys and the refusals. It takes no gate, so its caller holds one.
    static func withLatch(_ latched: Bool, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = [doneKey, latchKey].map { ($0, defaults.object(forKey: $0)) }
        let savedRefusals = SSOLoginService.storedPasswordRefusals
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            SSOLoginService.storedPasswordRefusals = savedRefusals
        }
        defaults.removeObject(forKey: doneKey)
        if latched { defaults.set(true, forKey: latchKey) } else { defaults.removeObject(forKey: latchKey) }
        SSOLoginService.forgetStoredPasswordRefusals()
        try await body()
    }

    @Test func aLatchedDeviceGetsOneTryAtOnceAndThenWaitsSixHours() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(true) {
                StoredPasswordLatchRetryMigration.runIfNeeded()
                let now = Date()

                #expect(!SSOLoginService.storedPasswordPostMustWait(now: now))
                #expect(UserDefaults.standard.object(forKey: Self.latchKey) == nil)
                SSOLoginService.noteStoredPasswordRefused(at: now)
                #expect(SSOLoginService.storedPasswordRetryAt(now: now)
                    == now.addingTimeInterval(SSOLoginService.storedPasswordRetryInterval))
            }
        }
    }

    @Test func aDeviceTheLatchNeverHeldKeepsNoRefusals() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(false) {
                StoredPasswordLatchRetryMigration.runIfNeeded()

                #expect(SSOLoginService.storedPasswordRefusals.count == 0)
                #expect(SSOLoginService.storedPasswordRetryAt(now: Date()) == nil)
            }
        }
    }

    @Test func itRunsOnce() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(false) {
                StoredPasswordLatchRetryMigration.runIfNeeded()
                UserDefaults.standard.set(true, forKey: Self.latchKey)
                StoredPasswordLatchRetryMigration.runIfNeeded()

                #expect(SSOLoginService.storedPasswordRefusals.count == 0)
            }
        }
    }
}
