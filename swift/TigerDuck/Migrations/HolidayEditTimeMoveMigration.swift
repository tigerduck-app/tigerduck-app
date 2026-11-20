import Defaults
import Foundation

enum HolidayEditTimeMoveMigration {
    private static let doneKey = "HolidayEditTimeMoveMigration.v1.done"

    static func runIfNeeded() {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        let earlier = Defaults.Key<[String: Date]>("holidayOverrideEditTimes", default: [:])
        let times = Defaults[earlier]
        earlier.reset()
        guard !times.isEmpty else { return }
        Defaults[.holidayOverrideEditClocks, for: AccountSession.school.currentSignIn] = times
            .mapValues { EditTime(wall: $0) }
            .merging(Defaults[.holidayOverrideEditClocks]) { _, kept in kept }
    }
}
