import WidgetKit
import SwiftUI

struct NextClassEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let derived: WidgetDerivedState
}

struct NextClassProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(date: Date(), snapshot: Self.emptySnapshot, derived: .signInRequired)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        completion(NextClassEntry(
            date: Date(),
            snapshot: snap,
            derived: WidgetTimelineDerivation.derive(snapshot: snap, at: Date())
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        let now = Date()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let entries = dates.map { date in
            NextClassEntry(
                date: date,
                snapshot: snap,
                derived: WidgetTimelineDerivation.derive(snapshot: snap, at: date)
            )
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static let emptySnapshot = WidgetSnapshot(
        version: 1, generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: false,
        accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
        periodOrder: [], activeWeekdays: [], activePeriodIds: []
    )
}

struct NextClassWidgetView: View {
    let entry: NextClassEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        NextClassView(derived: entry.derived, palette: palette, family: family)
            .padding(family == .systemSmall ? 10 : 14)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct NextClassWidget: Widget {
    let kind: String = "NextClassWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_next_class_light_label"))
        .description(String(localized: "widget_next_class_light_desc"))
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}
