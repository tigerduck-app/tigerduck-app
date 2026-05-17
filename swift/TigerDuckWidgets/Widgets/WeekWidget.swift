import WidgetKit
import SwiftUI

struct WeekEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct WeekProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> WeekEntry {
        WeekEntry(date: AppClock.now(), snapshot: Self.emptySnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (WeekEntry) -> Void) {
        completion(WeekEntry(date: AppClock.now(), snapshot: store.readSnapshot() ?? Self.emptySnapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WeekEntry>) -> Void) {
        // Week grid only needs to refresh at midnight (to advance the
        // "today" underline). The cells themselves are time-of-day
        // independent, so a single entry + .after(midnight) policy
        // is enough.
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        let appMidnight = Calendar(identifier: .gregorian).startOfDay(for: AppClock.now().addingTimeInterval(86_400))
        // WidgetKit interprets `.after(...)` against real wall-clock time,
        // so translate the fake-clock midnight to the real instant it maps
        // to. Identity when no debug override is active.
        let midnight = AppClock.realTime(forApp: appMidnight)
        completion(Timeline(entries: [WeekEntry(date: AppClock.now(), snapshot: snap)], policy: .after(midnight)))
    }

    private static let emptySnapshot = WidgetSnapshot(
        version: 1, generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: false,
        accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
        periodOrder: [], activeWeekdays: [], activePeriodIds: []
    )
}

struct WeekWidgetView: View {
    let entry: WeekEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        WeekGridView(snapshot: entry.snapshot, now: entry.date, palette: palette)
            .padding(3)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct WeekWidget: Widget {
    let kind: String = "WeekWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: WeekProvider()) { entry in
            WeekWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_week_light_label"))
        .description(String(localized: "widget_week_light_desc"))
        // iPad gets the larger family; iPhone-only families are filtered
        // automatically by WidgetKit. The grid view clamps its own minimum
        // cell height so the edit-mode resize preview never collapses to
        // an invisible state when iOS asks for an intermediate size.
        .supportedFamilies([.systemLarge, .systemExtraLarge])
        .contentMarginsDisabled()
    }
}
