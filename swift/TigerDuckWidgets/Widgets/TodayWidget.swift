import WidgetKit
import SwiftUI
import TigerDuckCore

struct TodayEntry: TimelineEntry {
    let date: Date
    let appNow: Date
    let snapshot: WidgetSnapshot
}

struct TodayProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        TodayEntry(date: Date(), appNow: AppClock.now(), snapshot: Self.emptySnapshot)
    }

    func snapshot(for configuration: ChooseClassTableIntent, in context: Context) async -> TodayEntry {
        TodayEntry(
            date: Date(),
            appNow: AppClock.now(),
            snapshot: WidgetSnapshotStore().readSnapshot(of: configuration.personID) ?? Self.emptySnapshot
        )
    }

    func timeline(for configuration: ChooseClassTableIntent, in context: Context) async -> Timeline<TodayEntry> {
        let snap = WidgetSnapshotStore().readSnapshot(of: configuration.personID) ?? Self.emptySnapshot
        let now = AppClock.now()
        let dates = Set(
            WidgetTimelineDerivation.entryDates(snapshot: snap, after: now)
                + WidgetDayLayout.ticks(snapshot: snap, after: now)
        ).sorted()
        // `entryDates` are app-clock boundaries, but WidgetKit schedules entries on the real
        // clock. Stamp each entry with the real-time equivalent and carry the app-clock boundary
        let entries = dates.map { appDate in
            TodayEntry(
                date: AppClock.realTime(forApp: appDate),
                appNow: appDate,
                snapshot: snap
            )
        }
        // With no courses or no signed-in user, `.atEnd` would make WidgetKit reload the single
        // placeholder entry in an immediate loop. Refreshing at midnight retries once a day.
        let hasCourses = snap.isLoggedIn && !snap.courses.isEmpty
        let policy: TimelineReloadPolicy = hasCourses
            ? .atEnd
            : .after(WidgetTimelineDerivation.nextMidnight(after: Date()))
        return Timeline(entries: entries, policy: policy)
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
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette.resolve(
            snapshot: entry.snapshot,
            colorScheme: colorScheme,
            renderingMode: renderingMode
        )
        TodayView(snapshot: entry.snapshot, now: entry.appNow, palette: palette, family: family)
            .containerBackground(palette.canvas, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
    }
}

struct TodayWidget: Widget {
    let kind: String = "TodayWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ChooseClassTableIntent.self, provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_today_light_label"))
        .description(String(localized: "widget_today_light_desc"))
        .supportedFamilies(WidgetFamily.withExtraLargePortrait([.systemMedium, .systemLarge, .systemExtraLarge]))
    }
}
