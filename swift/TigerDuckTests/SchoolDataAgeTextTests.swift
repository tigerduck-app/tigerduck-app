import Foundation
import Testing
@testable import TigerDuck

@MainActor
struct SchoolDataAgeTextTests {
    @Test("the age reads never synced, just now, then minutes, hours and days")
    func ageSteps() {
        let now = Date()
        #expect(SyncStatusDot.schoolDataAgeText(nil, now: now) == String(localized: "sync_status_never_synced"))
        #expect(SyncStatusDot.schoolDataAgeText(now - 59, now: now) == String(localized: "sync_status_just_now"))
        #expect(SyncStatusDot.schoolDataAgeText(now - 5 * 60, now: now)
            == String(format: String(localized: "sync_status_minutes_ago_short"), 5))
        #expect(SyncStatusDot.schoolDataAgeText(now - 2 * 3600 - 59, now: now)
            == String(format: String(localized: "sync_status_hours_ago_short"), 2))
        #expect(SyncStatusDot.schoolDataAgeText(now - 3 * 86_400, now: now)
            == String(format: String(localized: "sync_status_days_ago_short"), 3))
    }

    @Test("a stamp ahead of this device's clock reads just now")
    func futureStampReadsJustNow() {
        let now = Date()
        #expect(SyncStatusDot.schoolDataAgeText(now + 120, now: now) == String(localized: "sync_status_just_now"))
    }
}
