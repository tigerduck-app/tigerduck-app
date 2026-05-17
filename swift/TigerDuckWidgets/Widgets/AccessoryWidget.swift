import WidgetKit
import SwiftUI

struct AccessoryEntry: TimelineEntry {
    let date: Date
    let derived: WidgetDerivedState
}

struct AccessoryProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> AccessoryEntry {
        AccessoryEntry(date: AppClock.now(), derived: .signInRequired)
    }

    func getSnapshot(in context: Context, completion: @escaping (AccessoryEntry) -> Void) {
        let snap = store.readSnapshot()
        let derived: WidgetDerivedState = snap.map {
            WidgetTimelineDerivation.derive(snapshot: $0, at: AppClock.now())
        } ?? .signInRequired
        completion(AccessoryEntry(date: AppClock.now(), derived: derived))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AccessoryEntry>) -> Void) {
        guard let snap = store.readSnapshot() else {
            completion(Timeline(
                entries: [AccessoryEntry(date: AppClock.now(), derived: .signInRequired)],
                policy: .atEnd
            ))
            return
        }
        let now = AppClock.now()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        // `entryDates` are app-clock boundaries; WidgetKit schedules
        // entries against the real wall clock. Drive `derived` from the
        // app-clock date but stamp the entry with the real-time
        // equivalent so a fake-clock override actually advances the
        // accessory through its boundaries.
        let entries = dates.map { appDate in
            AccessoryEntry(
                date: AppClock.realTime(forApp: appDate),
                derived: WidgetTimelineDerivation.derive(snapshot: snap, at: appDate)
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
