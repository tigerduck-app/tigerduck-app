import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "SemesterResetClockSeedMigration.v1.done"

@MainActor
struct SemesterResetClockSeedMigrationTests {
    @Test("A reset an earlier build recorded only by when it landed gets that moment as its reset clock, so its tombstones stay this device's own")
    func landedResetsSeedTheirClocks() async {
        await withExclusiveRealDefaults {
            let saved = (Defaults[.semesterResetAt], Defaults[.semesterResetClocks], UserDefaults.standard.object(forKey: doneKey))
            defer {
                Defaults[.semesterResetAt, for: testSignIn] = saved.0
                Defaults[.semesterResetClocks, for: testSignIn] = saved.1
                if let done = saved.2 {
                    UserDefaults.standard.set(done, forKey: doneKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: doneKey)
                }
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            let landedAt = Date(timeIntervalSince1970: 1_790_000_000.25)
            Defaults[.semesterResetAt, for: testSignIn] = ["1151": landedAt, "1142": landedAt]
            Defaults[.semesterResetClocks, for: testSignIn] = ["1142": 7]

            SemesterResetClockSeedMigration.runIfNeeded()

            let clocks = Defaults[.semesterResetClocks]
            #expect(clocks == ["1151": 1_790_000_000_250_000, "1142": 7])
            let tombstone = { (hlc: Int64) in ServerTombstone(["kind": "reset", "hlc": NSNumber(value: hlc)]) }
            #expect(tombstone(1_790_000_000_250_000).isOwnReset(resetClock: clocks["1151"]))
            #expect(!tombstone(1_790_000_000_250_001).isOwnReset(resetClock: clocks["1151"]))
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
