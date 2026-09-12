// Pins `BulletinPushOptOutMigration`'s behaviour against the real, process-
// wide `Defaults`/`UserDefaults.standard` — there is no seam to fake here
// (unlike `PendingReminderPurgeMigration`'s `PendingReminderPurgeCenter`):
// the migration's whole job is reading and writing three real `Defaults`
// keys, so the test doubles as the only place that can observe it. Suite is
// `.serialized` and every test resets the doneKey and all three flags to
// their defaults first, for the same reason `PendingReminderPurgeMigration
// Tests` does: these live in real, process-wide `UserDefaults.standard`
// (no `Defaults.suite` override — see `AppDefaults.swift`), so Swift
// Testing's default parallel execution would otherwise let tests race on
// the same storage.
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

    init() {
        UserDefaults.standard.removeObject(forKey: doneKey)
        Defaults.reset(.pushServerEnabled, .bulletinPushEnabled, .serverPushUserOptOut)
    }

    // MARK: - Tests

    @Test("a 2.0.x false reading re-arms the push stack, marks bulletins off, and opts out of operator pushes")
    func falseReadingReArmsPushAndDisablesBulletins() {
        Defaults[.pushServerEnabled] = false
        Defaults[.serverPushUserOptOut] = false

        BulletinPushOptOutMigration.runIfNeeded()

        #expect(Defaults[.pushServerEnabled] == true)
        #expect(Defaults[.bulletinPushEnabled] == false)
        #expect(Defaults[.serverPushUserOptOut] == true)
    }

    @Test("a false reading never flips an already-true serverPushUserOptOut back to false")
    func falseReadingNeverUndoesAnExistingOperatorOptOut() {
        // A user who separately opted out of operator pushes on the
        // TigerSync page before upgrading must stay opted out — this
        // migration only ever writes `true` to `serverPushUserOptOut`.
        Defaults[.pushServerEnabled] = false
        Defaults[.serverPushUserOptOut] = true

        BulletinPushOptOutMigration.runIfNeeded()

        #expect(Defaults[.serverPushUserOptOut] == true)
    }

    @Test("a true reading touches nothing")
    func trueReadingTouchesNothing() {
        Defaults[.pushServerEnabled] = true
        Defaults[.bulletinPushEnabled] = true
        Defaults[.serverPushUserOptOut] = false

        BulletinPushOptOutMigration.runIfNeeded()

        #expect(Defaults[.pushServerEnabled] == true)
        #expect(Defaults[.bulletinPushEnabled] == true)
        #expect(Defaults[.serverPushUserOptOut] == false)
    }

    @Test("a second run after the flag is set does nothing")
    func secondRunIsNoOp() {
        Defaults[.pushServerEnabled] = false
        BulletinPushOptOutMigration.runIfNeeded()
        #expect(Defaults[.pushServerEnabled] == true)
        #expect(Defaults[.bulletinPushEnabled] == false)

        // Flip the flag back to `false` by hand, as if some other write set
        // it again. If the doneKey guard were not honoured, a second run
        // would re-apply the same rewrite; instead it must leave this
        // exactly as set here.
        Defaults[.pushServerEnabled] = false
        BulletinPushOptOutMigration.runIfNeeded()

        #expect(Defaults[.pushServerEnabled] == false)
        #expect(Defaults[.bulletinPushEnabled] == false)
    }

    @Test("runs synchronously, so a caller with no await observes the migrated value the instant the call returns")
    func runsSynchronously() {
        // This is the ordering property `AppState+Lifecycle.swift` depends
        // on: `runIfNeeded()` is called with no `await`, above the `Task`
        // in `runPendingMigrations()`, strictly before `pushCoordinator
        // .enable()` reads `pushServerEnabled` later in the same `init()`.
        // A plain, non-`async` `@Test` function can only call a non-`async`
        // function with no suspension point — this would fail to compile
        // if `runIfNeeded()` were ever changed to `async`, and the
        // assertions below would fail if it ever deferred its writes into
        // an unstructured `Task` instead of applying them inline.
        Defaults[.pushServerEnabled] = false

        BulletinPushOptOutMigration.runIfNeeded()

        #expect(Defaults[.pushServerEnabled] == true)
        #expect(Defaults[.bulletinPushEnabled] == false)
    }
}
