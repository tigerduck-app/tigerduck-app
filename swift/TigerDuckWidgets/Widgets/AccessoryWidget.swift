import WidgetKit
import SwiftUI

struct AccessoryEntry: TimelineEntry {
    let date: Date
    let derived: WidgetDerivedState
}

struct AccessoryProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> AccessoryEntry {
        AccessoryEntry(date: Date(), derived: .signInRequired)
    }

    func getSnapshot(in context: Context, completion: @escaping (AccessoryEntry) -> Void) {
        let snap = store.readSnapshot()
        let derived: WidgetDerivedState = snap.map {
            WidgetTimelineDerivation.derive(snapshot: $0, at: Date())
        } ?? .signInRequired
        completion(AccessoryEntry(date: Date(), derived: derived))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccessoryEntry>) -> Void) {
        guard let snap = store.readSnapshot() else {
            completion(Timeline(
                entries: [AccessoryEntry(date: Date(), derived: .signInRequired)],
                policy: .atEnd
            ))
            return
        }
        let now = Date()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let entries = dates.map { date in
            AccessoryEntry(
                date: date,
                derived: WidgetTimelineDerivation.derive(snapshot: snap, at: date)
            )
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

struct AccessoryWidgetView: View {
    let entry: AccessoryEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryInline:      AccessoryInlineView(derived: entry.derived)
            case .accessoryCircular:    AccessoryCircularView(derived: entry.derived)
            case .accessoryRectangular: AccessoryRectangularView(derived: entry.derived)
            default:                    EmptyView()
            }
        }
        .widgetURL(URL(string: "tigerduck://classtable"))
        .widgetAccentable(true)
        .containerBackground(.clear, for: .widget)
    }
}

struct AccessoryWidget: Widget {
    let kind: String = "AccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: AccessoryProvider()) { entry in
            AccessoryWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_next_class_light_label"))
        .description(String(localized: "widget_next_class_light_desc"))
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
