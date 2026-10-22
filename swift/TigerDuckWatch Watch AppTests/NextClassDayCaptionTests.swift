import Foundation
import Testing
@testable import TigerDuckWatch_Watch_App

@MainActor
struct NextClassDayCaptionTests {

    private let tuesday = WatchCourse(
        id: "B", courseNo: "B", name: "B", teacher: "", classroom: "TR-313", colorHex: "#FF8800",
        weekday: 2, startHHmm: "08:10", endHHmm: "09:00", periodLabel: "1"
    )

    private func entry(next: WatchCourse?, day: NextClassResolver.Day) -> NextClassEntry {
        NextClassEntry(
            date: Date(), current: nil, next: next, nextDay: day,
            accentHex: "#FF8800", languageTag: nil, relevance: nil
        )
    }

    private func tomorrow(_ time: String) -> String {
        String.localizedStringWithFormat(String(localized: "widget_tomorrow_time"), time)
    }

    private var tue: String { String(localized: "weekday_tue_caption") }

    @Test func headline_namesTheDayTheClassMeets() {
        #expect(NextClassResolver.Day.today.headline == String(localized: "watch_next"))
        #expect(NextClassResolver.Day.tomorrow.headline == String(localized: "widget_tomorrow"))
        #expect(NextClassResolver.Day.later(weekday: 2).headline == tue)
    }

    @Test(arguments: zip(1...7, [
        "weekday_mon_caption", "weekday_tue_caption", "weekday_wed_caption", "weekday_thu_caption",
        "weekday_fri_caption", "weekday_sat_caption", "weekday_sun_caption",
    ]))
    func aLaterDay_isNamedByItsWeekday(weekday: Int, key: String) {
        let name = String(localized: String.LocalizationValue(key))
        #expect(NextClassResolver.Day.later(weekday: weekday).headline == name)
        #expect(NextClassResolver.Day.later(weekday: weekday).inlineCaption("08:10") == "\(name) 08:10")
    }

    @Test func inlineCaption_putsTheDayBeforeTheTime() {
        #expect(NextClassResolver.Day.today.inlineCaption("08:10") == "08:10")
        #expect(NextClassResolver.Day.tomorrow.inlineCaption("08:10") == tomorrow("08:10"))
    }

    @Test func rectangular_captionsTheTimeRange() {
        #expect(RectangularView(entry: entry(next: tuesday, day: .tomorrow)).subhead == tomorrow("08:10–09:00"))
        #expect(RectangularView(entry: entry(next: tuesday, day: .later(weekday: 2))).subhead == "\(tue) 08:10–09:00")
        #expect(RectangularView(entry: entry(next: tuesday, day: .today)).subhead == "08:10–09:00")
    }

    @Test func inline_captionsTheStartTime() {
        #expect(InlineView(entry: entry(next: tuesday, day: .tomorrow)).text == "B · \(tomorrow("08:10"))")
        #expect(InlineView(entry: entry(next: tuesday, day: .later(weekday: 2))).text == "B · \(tue) 08:10")
        #expect(InlineView(entry: entry(next: tuesday, day: .today)).text == "B · 08:10")
    }

    @Test func corner_captionsTheStartTime() {
        #expect(CornerView(entry: entry(next: tuesday, day: .tomorrow)).timeText == tomorrow("08:10"))
        #expect(CornerView(entry: entry(next: tuesday, day: .later(weekday: 2))).timeText == "\(tue) 08:10")
        #expect(CornerView(entry: entry(next: tuesday, day: .today)).timeText == "08:10")
    }

    @Test func captionKeysResolveInTheWatchAppAndTheComplication() throws {
        let keys = [
            "watch_next", "widget_tomorrow", "widget_tomorrow_time",
            "weekday_mon_caption", "weekday_tue_caption", "weekday_wed_caption", "weekday_thu_caption",
            "weekday_fri_caption", "weekday_sat_caption", "weekday_sun_caption",
        ]
        let appex = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("TigerDuckWatchWidgetExtension.appex"))
        let complication = try #require(Bundle(url: appex))
        let missing = "\u{0}"
        for bundle in [Bundle.main, complication] {
            #expect(bundle.localizations.contains("zh-Hant"))
            #expect(bundle.localizations.contains("en"))
            for localization in bundle.localizations {
                let lproj = try #require(bundle.path(forResource: localization, ofType: "lproj").flatMap(Bundle.init(path:)))
                for key in keys {
                    let value = lproj.localizedString(forKey: key, value: missing, table: nil)
                    #expect(value != missing, "\(key) is missing from \(localization) in \(bundle.bundleURL.lastPathComponent)")
                }
            }
        }
    }
}
