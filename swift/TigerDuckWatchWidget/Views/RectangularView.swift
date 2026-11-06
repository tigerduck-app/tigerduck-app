import SwiftUI
import WidgetKit
import TigerDuckCore

struct RectangularView: View {
    let entry: NextClassEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(headline)
                .font(.headline)
                .lineLimit(1)
            if let span = entry.currentSpan, let course = entry.current {
                HStack(spacing: 0) {
                    if let room {
                        roomText(room)
                            .layoutPriority(1)
                    }
                    timeText(room == nil ? subhead : " · \(subhead)")
                }
                .lineLimit(1)
                ClassCountdown(span: span, tint: course.color)
                    .padding(.top, 4)
            } else {
                if let room {
                    roomText(room)
                        .lineLimit(1)
                }
                timeText(subhead)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func timeText(_ text: String) -> some View {
        Text(text)
            .accessibilityLabel(spokenSubhead)
            .font(.subheadline)
            .minimumScaleFactor(0.75)
            .foregroundStyle(displayCourse?.dayChange?.start ?? displayCourse?.dayChange?.end != nil ? AnyShapeStyle(Color.changeInk) : AnyShapeStyle(.secondary))
    }

    @ViewBuilder
    private func roomText(_ room: String) -> some View {
        Group {
            if displayCourse?.dayChange?.room != nil {
                Label(room, systemImage: "arrow.left.arrow.right")
                    .labelStyle(ChangedRoomLabelStyle())
                    .foregroundStyle(Color.changeInk)
            } else {
                Text(room)
                    .foregroundStyle(displayCourse?.color ?? .accentColor)
            }
        }
        .font(.subheadline.bold())
        .minimumScaleFactor(0.6)
        .widgetAccentable()
    }

    private var displayCourse: WatchCourse? { entry.current ?? entry.next }
    private var headline: String { displayCourse?.name ?? entry.language.string("watch_no_upcoming_classes") }
    var subhead: String {
        guard let c = displayCourse else { return "—" }
        return entry.captioned(TimeRange.text(c.startHHmm, c.endHHmm))
    }
    var spokenSubhead: String {
        guard let c = displayCourse else { return "—" }
        return entry.captioned(TimeRange.spoken(c.startHHmm, c.endHHmm) { entry.language.string($0) })
    }
    var room: String? {
        guard let c = displayCourse, !c.classroom.isEmpty else { return nil }
        return c.classroom
    }
}
