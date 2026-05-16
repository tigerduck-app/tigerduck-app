import WidgetKit
import SwiftUI

struct LibraryShortcutEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot?
}

struct LibraryShortcutProvider: TimelineProvider {
    private let store = WidgetSnapshotStore()

    func placeholder(in context: Context) -> LibraryShortcutEntry {
        LibraryShortcutEntry(date: AppClock.now(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (LibraryShortcutEntry) -> Void) {
        completion(LibraryShortcutEntry(date: AppClock.now(), snapshot: store.readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<LibraryShortcutEntry>) -> Void) {
        // Library Shortcut is static — single entry, refresh at midnight only
        // so the date used by `containerBackground` rolls over for any future
        // theme-tied logic. No dependency on snapshot freshness.
        let snapshot = store.readSnapshot()
        let entry = LibraryShortcutEntry(date: AppClock.now(), snapshot: snapshot)
        let midnight = Calendar(identifier: .gregorian).startOfDay(for: AppClock.now().addingTimeInterval(86_400))
        completion(Timeline(entries: [entry], policy: .after(midnight)))
    }
}

struct LibraryShortcutWidgetView: View {
    let entry: LibraryShortcutEntry
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = entry.snapshot.map {
            WidgetPalette.resolve(snapshot: $0, colorScheme: colorScheme)
        } ?? WidgetPalette.resolve(snapshot: Self.fallbackSnapshot, colorScheme: colorScheme)
        LibraryShortcutView(palette: palette)
            .containerBackground(palette.background, for: .widget)
            .widgetURL(URL(string: "tigerduck://library"))
    }

    private static let fallbackSnapshot = WidgetSnapshot(
        version: 1,
        generatedAt: Date(timeIntervalSince1970: 0),
        isLoggedIn: false,
        accentColorHex: 0x007AFF,
        courses: [],
        periodTimes: [:],
        periodOrder: [],
        activeWeekdays: [],
        activePeriodIds: []
    )
}

struct LibraryShortcutWidget: Widget {
    let kind: String = "LibraryShortcutWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: LibraryShortcutProvider()) { entry in
            LibraryShortcutWidgetView(entry: entry)
        }
        .configurationDisplayName(String(localized: "widget_library_shortcut_label", defaultValue: "Library QR Shortcut"))
        .description(String(localized: "widget_library_shortcut_desc", defaultValue: "Open the virtual library pass QR code in one tap"))
        .supportedFamilies([.systemSmall])
    }
}
