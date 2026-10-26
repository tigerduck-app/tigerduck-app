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

    var language: WatchLanguage { WatchLanguage(tag: languageTag) }
}
