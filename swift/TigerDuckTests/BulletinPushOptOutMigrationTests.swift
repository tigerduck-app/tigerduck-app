import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "BulletinPushOptOutMigration.v1.done"

@Suite("Bulletin push opt-out migration", .serialized)
@MainActor
struct BulletinPushOptOutMigrationTests {

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
            Defaults[.pushServerEnabled] = false
            Defaults[.serverPushUserOptOut] = true

            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.serverPushUserOptOut] == true)
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

            Defaults[.pushServerEnabled] = false
            BulletinPushOptOutMigration.runIfNeeded()

            #expect(Defaults[.pushServerEnabled] == false)
            #expect(Defaults[.bulletinPushEnabled] == false)
        }
    }
}
