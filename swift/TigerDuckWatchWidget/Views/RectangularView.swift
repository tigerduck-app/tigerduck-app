import SwiftUI
import WidgetKit

struct RectangularView: View {
    let entry: NextClassEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.headline)
                .lineLimit(1)
                .widgetAccentable()
            Text(subhead)
                .font(.subheadline)
                .lineLimit(1)
            if let room = displayRoom {
                Text(room)
                    .font(.caption2)
                    .lineLimit(1)
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var displayCourse: WatchCourse? { entry.current ?? entry.next }
    private var headline: String { displayCourse?.name ?? entry.language.string("watch_no_upcoming_classes") }
    var subhead: String {
        guard let c = displayCourse else { return "—" }
        let range = "\(c.startHHmm)–\(c.endHHmm)"
        return entry.current == nil ? entry.nextDay.inlineCaption(range, in: entry.language) : range
    }
    private var displayRoom: String? {
        guard let c = displayCourse, !c.classroom.isEmpty else { return nil }
        return c.classroom
    }
}
