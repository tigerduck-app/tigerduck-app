import WidgetKit
import SwiftUI
import TigerDuckCore

struct WeekEntry: TimelineEntry {
    let date: Date
    let appNow: Date
    let snapshot: WidgetSnapshot
}

struct WeekProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> WeekEntry {
        WeekEntry(date: Date(), appNow: AppClock.now(), snapshot: Self.emptySnapshot)
    }

    func snapshot(for configuration: ChooseClassTableIntent, in context: Context) async -> WeekEntry {
        WeekEntry(
            date: Date(),
            appNow: AppClock.now(),
            snapshot: WidgetSnapshotStore().readSnapshot(of: configuration.personID) ?? Self.emptySnapshot
        )
    }

    func timeline(for configuration: ChooseClassTableIntent, in context: Context) async -> Timeline<WeekEntry> {
        let snap = WidgetSnapshotStore().readSnapshot(of: configuration.personID) ?? Self.emptySnapshot
        let now = AppClock.now()
        let appDates = [now] + WidgetDayLayout.ticks(snapshot: snap, after: now)
        // WidgetKit interprets `.after(...)` against real wall-clock time,
        // so translate the fake-clock midnight to the real instant it maps
        // to. Identity when no debug override is active.
        let midnight = AppClock.realTime(forApp: WidgetTimelineDerivation.nextMidnight(after: now))
        return Timeline(
            entries: appDates.map { WeekEntry(date: AppClock.realTime(forApp: $0), appNow: $0, snapshot: snap) },
            policy: .after(midnight)
        )
    }

    private static let emptySnapshot = WidgetSnapshot(
        version: 1, generatedAt: Date(timeIntervalSince1970: 0), isLoggedIn: false,
        accentColorHex: 0x007AFF, courses: [], periodTimes: [:],
        periodOrder: [], activeWeekdays: [], activePeriodIds: []
    )
}

struct WeekWidgetView: View {
    let entry: WeekEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette.resolve(
            snapshot: entry.snapshot,
            colorScheme: colorScheme,
            renderingMode: renderingMode
        )
        WeekGridView(snapshot: entry.snapshot, now: entry.appNow, palette: palette, family: family)
            .padding(family == .systemLarge ? 8 : 10)
            .containerBackground(palette.canvas, for: .widget)
            .widgetURL(URL(string: "tigerduck://classtable"))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
    }
}

struct WeekWidget: Widget {
    let kind: String = "WeekWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ChooseClassTableIntent.self, provider: WeekProvider()) { entry in
            WeekWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_week_light_label"))
        .description(String(localized: "widget_week_light_desc"))
        // iPad gets the larger family; WidgetKit drops it on iPhone. The grid clamps its minimum
        // cell height so the edit-mode resize preview never collapses to an invisible state when
        // iOS asks for an intermediate size.
        .supportedFamilies(WidgetFamily.withExtraLargePortrait([.systemLarge, .systemExtraLarge]))
        .contentMarginsDisabled()
    }
}
