import SwiftUI
import WidgetKit

struct NextClassWidget: Widget {
    let kind: String = "NextClassWidget"

    var body: some WidgetConfiguration {
        // Snapshot-derived locale drives the static configuration strings.
        // The per-entry view re-applies `entry.locale` so the locale survives
        // even if the snapshot file isn't readable at widget-config time.
        let metaLocale = Self.snapshotLocale()
        return StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassWidgetEntryView(entry: entry)
                .environment(\.locale, entry.locale)
                .modifier(WatchTheme(snapshot: nil))
        }
        .configurationDisplayName(String(localized: "watch_widget_next_class", locale: metaLocale))
        .description(String(localized: "watch_widget_next_class_description", locale: metaLocale))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }

    private static func snapshotLocale() -> Locale {
        let url = SharedAppGroup.snapshotFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WatchSnapshot.self, from: data),
              let tag = snap.languageTag
        else { return .current }
        return Locale(identifier: tag)
    }
}

struct NextClassWidgetEntryView: View {
    @Environment(\.widgetFamily) var family
    let entry: NextClassEntry

    var body: some View {
        switch family {
        case .accessoryCircular:    CircularView(entry: entry)
        case .accessoryRectangular: RectangularView(entry: entry)
        case .accessoryInline:      InlineView(entry: entry)
        case .accessoryCorner:      CornerView(entry: entry)
        default:                    EmptyView()
        }
    }
}
