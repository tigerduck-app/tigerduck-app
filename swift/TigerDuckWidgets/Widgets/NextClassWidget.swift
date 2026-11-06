import WidgetKit
import SwiftUI

struct NextClassEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    let derived: WidgetDerivedState
    var upNext: WidgetDerivedState.NextInfo? = nil

    init(date: Date, snapshot: WidgetSnapshot, at appDate: Date) {
        self.date = date
        self.snapshot = snapshot
        derived = WidgetTimelineDerivation.derive(snapshot: snapshot, at: appDate)
        upNext = WidgetTimelineDerivation.upNext(snapshot: snapshot, at: appDate, after: derived)
    }
}

struct NextClassProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> NextClassEntry {
        NextClassEntry(date: Date(), snapshot: Self.emptySnapshot, at: AppClock.now())
    }

    func getSnapshot(in context: Context, completion: @escaping (NextClassEntry) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        completion(NextClassEntry(date: Date(), snapshot: snap, at: AppClock.now()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextClassEntry>) -> Void) {
        let snap = store.readSnapshot() ?? Self.emptySnapshot
        let now = AppClock.now()
        let dates = Set(
            WidgetTimelineDerivation.entryDates(snapshot: snap, after: now) + WidgetDayLayout.ticks(snapshot: snap, after: now)
        ).sorted()
        // `entryDates` are app-clock boundaries (possibly fake), but WidgetKit schedules entries
        // on the real clock. Derive the state from the app-clock date and stamp the entry with its
        // real-time equivalent so the timeline still advances under a fake-clock override.
        let entries = dates.map { appDate in
            NextClassEntry(date: AppClock.realTime(forApp: appDate), snapshot: snap, at: appDate)
        }
        // With no courses or no signed-in user, `.atEnd` would make WidgetKit reload the single
        // placeholder entry in an immediate loop. Refreshing at midnight retries once a day.
        let hasCourses = snap.isLoggedIn && !snap.courses.isEmpty
        let policy: TimelineReloadPolicy = hasCourses
            ? .atEnd
            : .after(WidgetTimelineDerivation.nextMidnight(after: Date()))
        completion(Timeline(entries: entries, policy: policy))
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
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let palette = WidgetPalette.resolve(
            snapshot: entry.snapshot,
            colorScheme: colorScheme,
            renderingMode: renderingMode
        )
        NextClassView(derived: entry.derived, upNext: entry.upNext, palette: palette, family: family)
            .padding(family == .systemSmall ? 14 : 11)
            .containerBackground(
                family == .systemSmall ? NextClassSmallView.background(of: entry.derived, palette: palette) : palette.canvas,
                for: .widget
            )
            .widgetURL(URL(string: "tigerduck://classtable"))
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
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
        .contentMarginsDisabled()
    }
}
