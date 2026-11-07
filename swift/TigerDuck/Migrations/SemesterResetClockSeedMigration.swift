import Defaults
import Foundation

enum SemesterResetClockSeedMigration {
    private static let doneKey = "SemesterResetClockSeedMigration.v1.done"

    static func runIfNeeded() {
        guard !AppUserDefaults.standard.bool(forKey: doneKey) else { return }
        defer { AppUserDefaults.standard.set(true, forKey: doneKey) }
        let landed = Defaults[.semesterResetAt].mapValues { PushAPI.clock(of: $0) }
        guard !landed.isEmpty else { return }
        Defaults[.semesterResetClocks, for: AccountSession.school.currentSignIn] = landed
            .merging(Defaults[.semesterResetClocks]) { _, kept in kept }
    }
}
