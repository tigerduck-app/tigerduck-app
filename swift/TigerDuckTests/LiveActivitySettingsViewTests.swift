import Foundation
import Testing
@testable import TigerDuck

@Suite("Live Activity lead-time label formatting")
@MainActor
struct LiveActivitySettingsViewTests {
    @Test("a half-hour-past-an-hour lead time renders its own value, not the nearest whole hour")
    func halfHourPositionRendersExactly() {
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

@Suite("Live Activity permission link row")
struct LiveActivityPermissionGapTests {
    @Test("the row is hidden while the system switch a Live Activity needs is on")
    func hiddenWhenActivitiesEnabled() {
        #expect(LiveActivitySettingsView.permissionGapStatus(liveActivitiesEnabled: true) == nil)
    }

    @Test("the row appears, as not-granted, once that switch is off")
    func shownWhenActivitiesDisabled() {
        #expect(
            LiveActivitySettingsView.permissionGapStatus(liveActivitiesEnabled: false)?.text
                == String(localized: "permission_not_granted_tap_settings")
        )
    }
}
