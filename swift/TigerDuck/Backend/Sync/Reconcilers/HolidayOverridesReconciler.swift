import Foundation
import os

@MainActor
struct HolidayOverridesReconciler: CategoryReconciler {
    static let category = "holidays"
    var calendar: AcademicCalendarStore = .shared

    init(app _: AppEnvironment) {}

    func reconcile(_ pass: FullSyncPass) -> Bool {
        guard let rows = pass.json["holiday_overrides"] as? [[String: Any]] else { return false }
        let optedIn = Set(rows.compactMap { row -> Int? in
            guard row["notify"] as? Bool == true else { return nil }
            return row["holiday_id"] as? Int
        })
        return calendar.applySyncedOverrides(optedIn, fetchedAt: pass.fetchedAt, for: pass.signIn)
    }
}
