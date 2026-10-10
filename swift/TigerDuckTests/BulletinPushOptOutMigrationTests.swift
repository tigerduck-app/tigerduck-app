// Runs on the real `Defaults` keys, which are the migration's whole job, inside
// `withExclusiveRealDefaults`. Each key is restored as present or absent, not at its
// default, because the migration reads an absent doneKey as "not run yet".
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "BulletinPushOptOutMigration.v1.done"

@Suite("Bulletin push opt-out migration", .serialized)
// `@MainActor` because the migration is: the app target defaults every
// unannotated type to the main actor, and the app runs it from there.
@MainActor
struct BulletinPushOptOutMigrationTests {

    /// A flag as *stored*, not as read: `nil` when nothing has ever written
    /// the key and the read is the registered default. The three flags get
    /// the same present-or-absent treatment as `doneKey` — a key the test
    /// host had never written must not come back written, even at a value
    /// that reads identically.
    private static func storedFlag(_ key: Defaults.Key<Bool>) -> Bool? {
        key.suite.object(forKey: key.name) as? Bool
    }

    private static func restoreFlag(_ key: Defaults.Key<Bool>, to stored: Bool?) {
        if let stored {
            Defaults[key] = stored
        } else {
            Defaults.reset(key)
        }
    }

    private static func withRealMigrationKeys(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let savedPushServerEnabled = storedFlag(.pushServerEnabled)
            let savedBulletinPushEnabled = storedFlag(.bulletinPushEnabled)
            let savedServerPushUserOptOut = storedFlag(.serverPushUserOptOut)
            let savedDoneKey = UserDefaults.standard.object(forKey: doneKey) as? Bool
            defer {
                restoreFlag(.pushServerEnabled, to: savedPushServerEnabled)
                restoreFlag(.bulletinPushEnabled, to: savedBulletinPushEnabled)
                restoreFlag(.serverPushUserOptOut, to: savedServerPushUserOptOut)
                if let savedDoneKey {
                    UserDefaults.standard.set(savedDoneKey, forKey: doneKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: doneKey)
                }
            }

            UserDefaults.standard.removeObject(forKey: doneKey)
            Defaults.reset(.pushServerEnabled, .bulletinPushEnabled, .serverPushUserOptOut)
            body()
        }
    }

    // MARK: - Tests

    @Test("a 2.0.x false reading re-arms the push stack, marks bulletins off, and opts out of operator pushes")
    func falseReadingReArmsPushAndDisablesBulletins() async {
        await Self.withRealMigrationKeys {
            Defaults[.pushServerEnabled] = false
            Defaults[.serverPushUserOptOut] = false

            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.pushServerEnabled] == true)
            #expect(Defaults[.bulletinPushEnabled] == false)
            #expect(Defaults[.serverPushUserOptOut] == true)
        }
    }

    @Test("a false reading never flips an already-true serverPushUserOptOut back to false")
    func falseReadingNeverUndoesAnExistingOperatorOptOut() async {
        await Self.withRealMigrationKeys {
            // A user who separately opted out of operator pushes on the
            // TigerSync page before upgrading must stay opted out — this
            // migration only ever writes `true` to `serverPushUserOptOut`.
            Defaults[.pushServerEnabled] = false
            Defaults[.serverPushUserOptOut] = true

            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.serverPushUserOptOut] == true)
            // Check the other two too, so keeping an existing opt-out cannot be an
            // early return that passes the check above but skips the other writes.
            #expect(Defaults[.pushServerEnabled] == true)
            #expect(Defaults[.bulletinPushEnabled] == false)
        }
    }

    @Test("a true reading touches nothing")
    func trueReadingTouchesNothing() async {
        await Self.withRealMigrationKeys {
            Defaults[.pushServerEnabled] = true
            Defaults[.bulletinPushEnabled] = true
            Defaults[.serverPushUserOptOut] = false

            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.pushServerEnabled] == true)
            #expect(Defaults[.bulletinPushEnabled] == true)
            #expect(Defaults[.serverPushUserOptOut] == false)
        }
    }

    @Test("a second run after the flag is set does nothing")
    func secondRunIsNoOp() async {
        await Self.withRealMigrationKeys {
            Defaults[.pushServerEnabled] = false
            BulletinPushOptOutMigration.runIfNeeded()
            #expect(Defaults[.pushServerEnabled] == true)
            #expect(Defaults[.bulletinPushEnabled] == false)

            // Set the flag back to `false` by hand, as another write might. A second
            // run that ignored the doneKey would rewrite it; it must stay as set here.
            Defaults[.pushServerEnabled] = false
            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.pushServerEnabled] == false)
            #expect(Defaults[.bulletinPushEnabled] == false)
        }
    }
}
