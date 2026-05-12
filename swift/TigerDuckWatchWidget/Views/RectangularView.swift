import SwiftUI

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

    private var displayCourse: WatchCourse? { entry.next ?? entry.current }
    private var headline: String { displayCourse?.name ?? String(localized: "watch.no_classes_today") }
    private var subhead: String {
        guard let c = displayCourse else { return "—" }
        return "\(c.startHHmm)–\(c.endHHmm)"
    }
    private var displayRoom: String? {
        guard let c = displayCourse, !c.classroom.isEmpty else { return nil }
        return c.classroom
    }
}
