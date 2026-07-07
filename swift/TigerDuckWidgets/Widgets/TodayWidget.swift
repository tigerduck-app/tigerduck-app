import WidgetKit
import SwiftUI

struct TodayEntry: TimelineEntry {
    /// Real wall-clock instant WidgetKit treats this entry as current.
    let date: Date
    /// App-clock "now" used to render the row state (which class is
    /// current, next, past). Diverges from `date` only when the debug
    /// clock is overridden — kept separate so WidgetKit's scheduling
    /// stays on the real clock while the UI follows the fake one.
    let appNow: Date
    let snapshot: WidgetSnapshot
}

struct TodayProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), appNow: AppClock.now(), snapshot: Self.emptySnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(TodayEntry(
            date: Date(),
            appNow: AppClock.now(),
            snapshot: store.readSnapshot() ?? Self.emptySnapshot
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        let now = AppClock.now()
        let dates = WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
        // `entryDates` are app-clock boundaries; WidgetKit schedules
        // entries against the real wall clock. Stamp each entry with the
        // real-time equivalent for scheduling, and carry the app-clock
        // boundary in `appNow` so the row state at that moment is
        // rendered against fake time.
        let entries = dates.map { appDate in
            TodayEntry(
                date: AppClock.realTime(forApp: appDate),
                appNow: appDate,
                snapshot: snap
            )
        }
        // When the snapshot has no courses or the user isn't logged in,
        // `.atEnd` would spin WidgetKit in an immediate-reload loop on
        // the single placeholder entry. Refresh at midnight instead so
        // we retry once per day.
        let hasCourses = snap.isLoggedIn && !snap.courses.isEmpty
        let policy: TimelineReloadPolicy
        if hasCourses {
            policy = .atEnd
        } else {
            let startOfToday = Calendar.current.startOfDay(for: Date())
            let midnight = Calendar.current.date(byAdding: .day, value: 1, to: startOfToday)
                ?? startOfToday.addingTimeInterval(86400)
            policy = .after(midnight)
        }
        completion(Timeline(entries: entries, policy: policy))
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
        case .systemLarge:      return 8
        case .systemExtraLarge: return 16
        default:                return 8
        }
    }

    var body: some View {
        let palette = WidgetPalette.resolve(snapshot: entry.snapshot, colorScheme: colorScheme)
        TodayListView(snapshot: entry.snapshot, now: entry.appNow, palette: palette, maxRows: maxRows)
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
        .supportedFamilies([.systemLarge, .systemExtraLarge])
    }
}
