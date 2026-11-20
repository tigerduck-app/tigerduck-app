import Defaults
import Foundation
import Testing
@testable import TigerDuck

private let doneKey = "HolidayEditTimeMoveMigration.v1.done"

@MainActor
struct HolidayEditTimeMoveMigrationTests {
    private static let earlierTimes = Defaults.Key<[String: Date]>("holidayOverrideEditTimes", default: [:])

    @Test("The edit times an earlier build kept become wall-clock edit clocks, an edit clock already kept wins, and the old key goes")
    func earlierEditTimesMoveToTheEditClocks() async {
        await withExclusiveRealDefaults {
            let saved = (Defaults[.holidayOverrideEditClocks], UserDefaults.standard.object(forKey: doneKey))
            defer {
                Defaults[.holidayOverrideEditClocks, for: testSignIn] = saved.0
                if let done = saved.1 {
                    UserDefaults.standard.set(done, forKey: doneKey)
                } else {
                    UserDefaults.standard.removeObject(forKey: doneKey)
                }
                Self.earlierTimes.reset()
            }
            UserDefaults.standard.removeObject(forKey: doneKey)
            let madeAt = Date(timeIntervalSince1970: 1_790_000_000)
            let kept = EditTime(wall: madeAt.addingTimeInterval(60), sinceBoot: 5, boot: "boot-a")
            Defaults[Self.earlierTimes] = ["7": madeAt, "8": madeAt]
            Defaults[.holidayOverrideEditClocks, for: testSignIn] = ["8": kept]

            HolidayEditTimeMoveMigration.runIfNeeded()

            #expect(Defaults[.holidayOverrideEditClocks] == ["7": EditTime(wall: madeAt), "8": kept])
            #expect(UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["holidayOverrideEditTimes"] == nil)
            #expect(UserDefaults.standard.bool(forKey: doneKey))
        }
    }
}
