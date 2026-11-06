import WidgetKit
import Foundation
import TigerDuckCore

nonisolated struct NextClassEntry: TimelineEntry {
    let date: Date
    let current: WatchCourse?
    let next: WatchCourse?
    let nextDay: NextClassResolver.Day
    let currentSpan: ClosedRange<Date>?
    let accentHex: String
    let languageTag: String?
    let relevance: TimelineEntryRelevance?

    var language: WatchLanguage { WatchLanguage(tag: languageTag) }

    func captioned(_ time: String) -> String {
        current == nil ? nextDay.inlineCaption(time, in: language) : time
    }

    var spokenSummary: String {
        guard let course = current ?? next else { return language.string("watch_no_upcoming_classes") }
        return "\(course.roomOrName), \(captioned(TimeRange.spoken(course.startHHmm, course.endHHmm) { language.string($0) }))"
    }
}
