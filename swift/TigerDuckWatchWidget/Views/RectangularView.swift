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
                .foregroundStyle(displayCourse?.dayChange?.start ?? displayCourse?.dayChange?.end != nil ? Color.changeInk : .primary)
                .lineLimit(1)
            if let room = displayRoom {
                if displayCourse?.dayChange?.room != nil {
                    Label(room, systemImage: "arrow.left.arrow.right")
                        .labelStyle(ChangedRoomLabelStyle())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.changeInk)
                        .lineLimit(1)
                } else {
                    Text(room)
                        .font(.caption2)
                        .lineLimit(1)
                }
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
