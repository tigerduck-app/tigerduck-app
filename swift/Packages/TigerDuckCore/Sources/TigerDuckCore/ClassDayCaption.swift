import Foundation

extension ClassDay {
    public func headline(todayKey: LocalizedStringResource, in language: AppLanguage) -> String {
        switch self {
        case .today: language.string(todayKey)
        case .tomorrow: language.string("widget_tomorrow")
        case .later(let weekday): Self.caption(of: weekday, in: language)
        }
    }

    public func inlineCaption(_ time: String, in language: AppLanguage) -> String {
        switch self {
        case .today: time
        case .tomorrow: language.format("widget_tomorrow_time", time)
        case .later(let weekday): "\(Self.caption(of: weekday, in: language)) \(time)"
        }
    }

    private static func caption(of weekday: Int, in language: AppLanguage) -> String {
        switch weekday {
        case 1: language.string("weekday_mon_caption")
        case 2: language.string("weekday_tue_caption")
        case 3: language.string("weekday_wed_caption")
        case 4: language.string("weekday_thu_caption")
        case 5: language.string("weekday_fri_caption")
        case 6: language.string("weekday_sat_caption")
        default: language.string("weekday_sun_caption")
        }
    }
}
