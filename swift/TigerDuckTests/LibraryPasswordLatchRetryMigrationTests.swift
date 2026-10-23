import Foundation
import Testing
@testable import TigerDuck

@MainActor
@Suite(.serialized)
struct LibraryPasswordLatchRetryMigrationTests {
    static let doneKey = "LibraryPasswordLatchRetryMigration.v1.done"
    static let latchKey = "libraryStoredPasswordRejected"

    static func withLatch(_ latched: Bool, _ body: () async throws -> Void) async rethrows {
        let defaults = UserDefaults.standard
        let saved = [doneKey, latchKey].map { ($0, defaults.object(forKey: $0)) }
        let savedRefusals = LibraryService.storedPasswordRefusals
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            LibraryService.storedPasswordRefusals = savedRefusals
        }
        defaults.removeObject(forKey: doneKey)
        if latched { defaults.set(true, forKey: latchKey) } else { defaults.removeObject(forKey: latchKey) }
        LibraryService.storedPasswordRefusals = (0, nil)
        try await body()
    }

    @Test func aLatchedDeviceGetsOneTryAtOnceAndThenWaitsSixHours() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(true) {
                LibraryPasswordLatchRetryMigration.runIfNeeded()
                let now = Date()

                #expect(LibraryService.storedPasswordPostIsDue(now: now))
                #expect(UserDefaults.standard.object(forKey: Self.latchKey) == nil)
                LibraryService.storedPasswordRefusals = (LibraryService.storedPasswordRefusals.count + 1, now)
                #expect(!LibraryService.storedPasswordPostIsDue(now: now.addingTimeInterval(6 * 60 * 60 - 1)))
                #expect(LibraryService.storedPasswordPostIsDue(now: now.addingTimeInterval(6 * 60 * 60)))
            }
        }
    }

    @Test func aDeviceTheLatchNeverHeldKeepsNoRefusals() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(false) {
                LibraryPasswordLatchRetryMigration.runIfNeeded()

                #expect(LibraryService.storedPasswordRefusals.count == 0)
                #expect(LibraryService.storedPasswordPostIsDue(now: Date()))
            }
        }
    }

    @Test func itRunsOnce() async {
        await withExclusiveRealDefaults {
            await Self.withLatch(false) {
                LibraryPasswordLatchRetryMigration.runIfNeeded()
                UserDefaults.standard.set(true, forKey: Self.latchKey)
                LibraryPasswordLatchRetryMigration.runIfNeeded()

                #expect(LibraryService.storedPasswordRefusals.count == 0)
            }
        }
    }
}
