import WidgetKit
import Foundation

nonisolated struct NextClassEntry: TimelineEntry {
    let date: Date
    let current: WatchCourse?
    let next: WatchCourse?
    let nextDay: NextClassResolver.Day
    let accentHex: String
    let languageTag: String?
    let relevance: TimelineEntryRelevance?

    var locale: Locale {
        if let tag = languageTag { return Locale(identifier: tag) }
        return .current
    }
}
