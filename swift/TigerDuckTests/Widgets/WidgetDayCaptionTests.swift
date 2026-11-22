import Foundation
import Testing
@testable import TigerDuck
import TigerDuckCore

/// English names a day the same with the caption and the short keys, so these read zh-Hant,
/// where the two differ.
struct WidgetDayCaptionTests {
    private let zh = AppLanguage(tag: "zh-Hant")

    private static func value(_ key: String) throws -> String {
        let path = try #require(Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"))
        return try #require(Bundle(path: path)).localizedString(forKey: key, value: nil, table: nil)
    }

    @Test func theHeadlineNamesTheDayTheClassMeets() throws {
        #expect(WidgetDerivedState.Day.today.headline(todayKey: "widget_next_class", in: zh) == (try Self.value("widget_next_class")))
        #expect(WidgetDerivedState.Day.tomorrow.headline(todayKey: "widget_next_class", in: zh) == (try Self.value("widget_tomorrow")))
    }

    @Test(arguments: zip(1...7, ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]))
    func aLaterDayIsNamedByItsWeekdayCaption(weekday: Int, day: String) throws {
        let caption = try Self.value("weekday_\(day)_caption")
        #expect(caption != (try Self.value("weekday_\(day)_short")))

        #expect(WidgetDerivedState.Day.later(weekday: weekday).headline(todayKey: "widget_next_class", in: zh) == caption)
        #expect(WidgetDerivedState.Day.later(weekday: weekday).inlineCaption("08:10", in: zh) == "\(caption) 08:10")
    }

    @Test func tomorrowsInlineCaptionPutsTheDayBeforeTheClass() throws {
        let expected = String(format: try Self.value("widget_tomorrow_time"), "微積分 08:10")
        #expect(WidgetDerivedState.Day.tomorrow.inlineCaption("微積分 08:10", in: zh) == expected)
    }
}
