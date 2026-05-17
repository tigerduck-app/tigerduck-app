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
        NextClassEntry(date: AppClock.now(), snapshot: Self.emptySnapshot, derived: .signInRequired)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        completion(NextClassEntry(
            date: AppClock.now(),
            snapshot: snap,
            derived: WidgetTimelineDerivation.derive(snapshot: snap, at: AppClock.now())
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        let now = AppClock.now()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        // `entryDates` are app-clock boundaries (possibly fake), but
        // WidgetKit schedules entries on the real wall clock. Derive
        // the displayed state from the app-clock date, then stamp the
        // entry with the real-time equivalent so the timeline actually
        // advances under a fake-clock override.
        let entries = dates.map { appDate in
            NextClassEntry(
                date: AppClock.realTime(forApp: appDate),
                snapshot: snap,
                derived: WidgetTimelineDerivation.derive(snapshot: snap, at: appDate)
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
