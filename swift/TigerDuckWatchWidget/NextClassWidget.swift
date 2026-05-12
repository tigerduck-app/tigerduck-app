import SwiftUI
import WidgetKit

struct NextClassWidget: Widget {
    let kind: String = "NextClassWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextClassProvider()) { entry in
            NextClassWidgetEntryView(entry: entry)
                .modifier(WatchTheme(snapshot: nil)) // accent passed in entry; locale uses system
        }
        .configurationDisplayName(String(localized: "watch_widget_next_class"))
        .description(String(localized: "watch_widget_next_class_description"))
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
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
