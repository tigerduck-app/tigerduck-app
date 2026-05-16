import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), snapshot: Self.emptySnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(date: Date(), snapshot: store.readSnapshot() ?? Self.emptySnapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        let now = Date()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        let entries = dates.map { TodayEntry(date: $0, snapshot: snap) }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    private static let emptySnapshot = WidgetSnapshot(
        version: 1, generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: false,
        accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
        periodOrder: [], activeWeekdays: [], activePeriodIds: []
    )
}

struct TodayWidgetView: View {
    let entry: TodayEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme

    private var maxRows: Int {
        switch family {
        case .systemMedium:     return 4
        case .systemLarge:      return 8
        case .systemExtraLarge: return 16
        default:                return 4
        }
    }

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        TodayListView(snapshot: entry.snapshot, now: entry.date, palette: palette, maxRows: maxRows)
            .padding(12)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct TodayWidget: Widget {
    let kind: String = "TodayWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_today_light_label"))
        .description(String(localized: "widget_today_light_desc"))
        .supportedFamilies([.systemMedium, .systemLarge, .systemExtraLarge])
    }
}
