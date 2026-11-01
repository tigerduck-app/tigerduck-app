import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct StoredPasswordLatchRetryMigrationTests {
    static let doneKey = "StoredPasswordLatchRetryMigration.v1.done"
    static let latchKey = "ntustStoredPasswordRejected"

    static func withLatch(_ latched: Bool, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = [doneKey, latchKey].map { ($0, defaults.object(forKey: $0)) }
        let savedRefusals = SchoolPasswordPosts.storedPasswordRefusals
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            SchoolPasswordPosts.storedPasswordRefusals = savedRefusals
        }
        defaults.removeObject(forKey: doneKey)
        if latched { defaults.set(true, forKey: latchKey) } else { defaults.removeObject(forKey: latchKey) }
        SchoolPasswordPosts.forgetStoredPasswordRefusals()
        try await body()
    }

    @Test func aLatchedDeviceGetsOneTryAtOnceAndThenWaitsSixHours() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(true) {
                StoredPasswordLatchRetryMigration.runIfNeeded()
                let now = Date()

                #expect(!SchoolPasswordPosts.storedPasswordPostMustWait(now: now))
                #expect(UserDefaults.standard.object(forKey: Self.latchKey) == nil)
                SchoolPasswordPosts.noteStoredPasswordRefused(at: now)
                #expect(SchoolPasswordPosts.storedPasswordRetryAt(now: now)
                    == now.addingTimeInterval(StoredPasswordLockoutBackoff.retryInterval))
            }
        }
    }

    @Test func aDeviceTheLatchNeverHeldKeepsNoRefusals() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(false) {
                StoredPasswordLatchRetryMigration.runIfNeeded()

                #expect(SchoolPasswordPosts.storedPasswordRefusals.count == 0)
                #expect(SchoolPasswordPosts.storedPasswordRetryAt(now: Date()) == nil)
            }
        }
    }

    @Test func itRunsOnce() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(false) {
                StoredPasswordLatchRetryMigration.runIfNeeded()
                UserDefaults.standard.set(true, forKey: Self.latchKey)
                StoredPasswordLatchRetryMigration.runIfNeeded()

                #expect(SchoolPasswordPosts.storedPasswordRefusals.count == 0)
            }
        }
    }
}
