// The assignment lead-time slider steps by 30 minutes, so its label must keep the
// minutes: 5400s is 1h30m, not "1 hour". `formatHoursAndMinutes` is static and reads
// no store or `Defaults`, so it is called directly, with no view.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Live Activity lead-time label formatting")
struct LiveActivitySettingsViewTests {
    @Test("a half-hour-past-an-hour lead time renders its own value, not the nearest whole hour")
    func halfHourPositionRendersExactly() {
        // 5400s is 1h30m, a half-hour position. A whole hour such as 3600s reads the
        // same under an hours-only formatter, so it would prove nothing; 5400s is where
        // they differ ("1 hr" against "1 hr 30 min").
        let label = LiveActivitySettingsView.formatHoursAndMinutes(5400)
        let expected = String(format: String(localized: "live_activity_settings_hours_minutes_label"), 1, 30)
        #expect(label == expected)
    }

    @Test("whole-hour and whole-minute positions still use their own single-unit label")
    func wholeUnitPositionsOmitTheZeroUnit() {
        #expect(
            LiveActivitySettingsView.formatHoursAndMinutes(3600)
                == String(format: String(localized: "live_activity_settings_hours_label"), 1)
        )
        #expect(
            LiveActivitySettingsView.formatHoursAndMinutes(1800)
                == String(format: String(localized: "live_activity_settings_minutes_label"), 30)
        )
    }
}

// Whether the view shows a link row to Notification permission settings above its
// settings. `permissionGapStatus(liveActivitiesEnabled:)` is the whole rule (`nil`
// hides the row), so these two cases are the entire contract.
@Suite("Live Activity permission link row")
struct LiveActivityPermissionGapTests {
    @Test("the row is hidden while the system switch a Live Activity needs is on")
    func hiddenWhenActivitiesEnabled() {
        #expect(LiveActivitySettingsView.permissionGapStatus(liveActivitiesEnabled: true) == nil)
    }

    @Test("the row appears, as not-granted, once that switch is off")
    func shownWhenActivitiesDisabled() {
        // It reuses `NotificationPermissionSettingsView.RowStatus`, so the line matches
        // the permission screen's own row; asserting on `.text` pins that instead of a
        // second copy of the string.
        #expect(
            LiveActivitySettingsView.permissionGapStatus(liveActivitiesEnabled: false)?.text
                == String(localized: "permission_not_granted_tap_settings")
        )
    }
}
