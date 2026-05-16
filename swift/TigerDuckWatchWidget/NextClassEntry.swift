import WidgetKit
import Foundation

struct NextClassEntry: TimelineEntry {
    let date: Date
    let current: WatchCourse?
    let next: WatchCourse?
    let accentHex: String
    let relevance: TimelineEntryRelevance?
}
