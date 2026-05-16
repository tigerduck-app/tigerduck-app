import Foundation
import Testing
@testable import TigerDuck

struct WidgetLocalizationKeysTests {
    /// Every key referenced from widget SwiftUI views and widget definitions.
    /// Update this list when you add or remove a localized string in any
    /// widget view (`swift/TigerDuckWidgets/Views/`) or widget definition
    /// (`swift/TigerDuckWidgets/Widgets/`).
    private let keys: [String] = [
        // Chrome strings used by views
        "widget_sign_in",
        "widget_ongoing",
        "widget_next_class",
        "widget_next_class_short",
        "widget_until_time",
        "widget_tomorrow",
        "widget_tomorrow_time",
        "widget_no_more_classes",
        "widget_no_classes_today",
        "widget_no_classes_weekend",
        "widget_today_weekday_title",
        "widget_library_shortcut_title",
        // Gallery (configurationDisplayName / description)
        "widget_library_shortcut_label",
        "widget_library_shortcut_desc",
        "widget_next_class_light_label",
        "widget_next_class_light_desc",
        "widget_today_light_label",
        "widget_today_light_desc",
        "widget_week_light_label",
        "widget_week_light_desc",
        // Weekday shorts (used by Today + Week views)
        "weekday_mon_short",
        "weekday_tue_short",
        "weekday_wed_short",
        "weekday_thu_short",
        "weekday_fri_short",
        "weekday_sat_short",
        "weekday_sun_short",
    ]

    @Test func everyKeyResolvesInMainBundle() {
        // We can't load the widget extension's bundle from the test target
        // directly, but the keys live in the same shared `localization/`
        // submodule that symlinks into both the app and widget targets'
        // Localizable.strings. If they resolve in the main app's bundle
        // they resolve in the widget bundle too.
        for key in keys {
            let resolved = String(localized: String.LocalizationValue(key), bundle: .main)
            #expect(!resolved.isEmpty, "Key \(key) resolved to empty")
            #expect(resolved != key, "Key \(key) had no translation (got key back as value)")
        }
    }
}
