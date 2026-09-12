// Pins `BulletinPushOptOutMigration`'s behaviour against the real, process-
// wide `Defaults`/`UserDefaults.standard` — there is no seam to fake here
// (unlike `PendingReminderPurgeMigration`'s `PendingReminderPurgeCenter`):
// the migration's whole job is reading and writing three real `Defaults`
// keys, so the test doubles as the only place that can observe it.
//
// Every test runs inside `withRealMigrationKeys`, which takes the shared
// gate (`RealDefaultsGate.swift`), resets the doneKey and all three flags
// to their defaults, and afterwards puts back exactly what the test host
// held — the flags, and the doneKey as present-or-absent rather than
// present-and-`false`, which the migration reads as "not run yet".
//
// Restoring matters beyond tidiness: without it, `secondRunIsNoOp` leaves
// the test host's own UserDefaults with the flag off and the doneKey set,
// which used to be the never-registers state this migration exists to
// repair — reproduced on the developer's simulator for every later manual
// launch. The gate matters because `.serialized` orders this suite's tests
// against each other and nothing else, while `PushRegistrationServiceTests`
// pins two of the same keys across a 250 ms window.
//
// `doneKey` mirrors the migration's own private `UserDefaults.standard`
// flag literal ("BulletinPushOptOutMigration.v1.done"). Duplicated here
// rather than referenced because the production constant is intentionally
// `private`, matching every other migration in this folder — see
// Services/Migrations/AGENTS.md.
import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "BulletinPushOptOutMigration.v1.done"

@Suite("Bulletin push opt-out migration", .serialized)
struct BulletinPushOptOutMigrationTests {

    private static func withRealMigrationKeys(_ body: () -> Void) async {
        await withExclusiveRealDefaults {
            let savedPushServerEnabled = Defaults[.pushServerEnabled]
            let savedBulletinPushEnabled = Defaults[.bulletinPushEnabled]
            let savedServerPushUserOptOut = Defaults[.serverPushUserOptOut]
            let savedDoneKey = UserDefaults.standard.object(forKey: doneKey) as? Bool
            defer {
                Defaults[.pushServerEnabled] = savedPushServerEnabled
                Defaults[.bulletinPushEnabled] = savedBulletinPushEnabled
                Defaults[.serverPushUserOptOut] = savedServerPushUserOptOut
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
            // The other two as well, so that "leave an existing opt-out
            // alone" cannot be implemented as an early return above the
            // writes — that would pass the assertion above while leaving
            // this cohort's bulletin flag and migration marker untouched.
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

            // Flip the flag back to `false` by hand, as if some other write
            // set it again. If the doneKey guard were not honoured, a second
            // run would re-apply the same rewrite; instead it must leave
            // this exactly as set here.
            Defaults[.pushServerEnabled] = false
            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.pushServerEnabled] == false)
            #expect(Defaults[.bulletinPushEnabled] == false)
        }
    }
}
