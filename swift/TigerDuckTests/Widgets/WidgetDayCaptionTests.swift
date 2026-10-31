import Foundation
import Testing
@testable import TigerDuck
import TigerDuckCore

/// English names a day the same with the caption and the short keys, so these read zh-Hant,
/// where the two differ.
struct WidgetDayCaptionTests {
    private static func zhHant() throws -> Bundle {
        let path = try #require(Bundle.main.path(forResource: "zh-Hant", ofType: "lproj"))
        return try #require(Bundle(path: path))
    }

    private static func value(_ key: String, in bundle: Bundle) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    @Test func theHeadlineNamesTheDayTheClassMeets() throws {
        let zh = try Self.zhHant()
        #expect(WidgetDerivedState.Day.today.headline(in: zh) == Self.value("widget_next_class", in: zh))
        #expect(WidgetDerivedState.Day.tomorrow.headline(in: zh) == Self.value("widget_tomorrow", in: zh))
    }

    @Test(arguments: zip(1...7, ["mon", "tue", "wed", "thu", "fri", "sat", "sun"]))
    func aLaterDayIsNamedByItsWeekdayCaption(weekday: Int, day: String) throws {
        let zh = try Self.zhHant()
        let caption = Self.value("weekday_\(day)_caption", in: zh)
        #expect(caption != Self.value("weekday_\(day)_short", in: zh))

        #expect(WidgetDerivedState.Day.later(weekday: weekday).headline(in: zh) == caption)
        #expect(WidgetDerivedState.Day.later(weekday: weekday).inlineCaption("08:10", in: zh) == "\(caption) 08:10")
    }

    @Test func tomorrowsInlineCaptionPutsTheDayBeforeTheClass() throws {
        let zh = try Self.zhHant()
        let expected = String(format: Self.value("widget_tomorrow_time", in: zh), "微積分 08:10")
        #expect(WidgetDerivedState.Day.tomorrow.inlineCaption("微積分 08:10", in: zh) == expected)
    }
}
