import SwiftUI
import WidgetKit

struct NextClassWidget: Widget {
    let kind: String = "NextClassWidget"

    var body: some WidgetConfiguration {
        let language = Self.snapshotLanguage()
        return StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassWidgetEntryView(entry: entry)
                .environment(\.locale, entry.language.locale)
                .modifier(WatchTheme(snapshot: nil))
        }
        .configurationDisplayName(language.string("watch_widget_next_class"))
        .description(language.string("watch_widget_next_class_description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }

    private static func snapshotLanguage() -> WatchLanguage {
        let url = SharedAppGroup.snapshotFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(WatchSnapshot.self, from: data)
        else { return WatchLanguage(tag: nil) }
        return WatchLanguage(tag: snap.languageTag)
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
