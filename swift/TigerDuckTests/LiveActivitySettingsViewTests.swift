// `LiveActivitySettingsView.formatHoursAndMinutes` — the assignment-
// lead-time slider's `step` moved to 1800s (30 minutes), but its label
// was still driven by `formatHours` (`Int(interval / 3600)`), so 7 of the
// 15 reachable slider positions rendered a lead time that was not the one
// selected (5400s, i.e. 1h30m, rendered as "1 hour").
//
// `formatHoursAndMinutes` was lifted from `private` to `static` (dropping
// the `private` that made it untestable) rather than adding a SwiftUI
// view-inspection dependency for one assertion. It takes a plain
// `TimeInterval` and touches no `store`/`Defaults`, so this test calls it
// directly with no view or store construction involved.
import Foundation
import Testing
@testable import TigerDuck

@Suite("Live Activity lead-time label formatting (task-4 review Important 2)")
struct LiveActivitySettingsViewTests {
    @Test("a half-hour-past-an-hour lead time renders its own value, not the nearest whole hour")
    func halfHourPositionRendersExactly() {
        // 5400s = 1h30m — one of the seven newly-reachable half-hour
        // positions that the old `formatHours` mis-rendered. A whole-hour
        // input (3600s)
        // would render identically under the buggy `formatHours` and the
        // correct `formatHoursAndMinutes`, so asserting there would prove
        // nothing; 5400s is where they diverge ("1 hr" vs "1 hr 30 min").
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
