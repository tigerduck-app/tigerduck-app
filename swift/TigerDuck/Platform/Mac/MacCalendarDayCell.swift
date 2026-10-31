#if os(macOS)
import SwiftUI
import TigerDuckCore

/// One day of the Mac calendar's month grid: the date and a dot for each source of its events.
struct MacCalendarDayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let events: [AssignmentStore.CalendarEvent]
    let cellHeight: CGFloat
    let onTap: () -> Void

    private var accessibleDateString: String {
        date.formatted(Date.FormatStyle(
            date: .complete,
            time: .omitted,
            calendar: TaipeiTime.calendar,
            timeZone: TaipeiTime.timeZone
        ))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                Text("\(TaipeiTime.calendar.component(.day, from: date))")
                    .font(.callout.weight(isToday || isSelected ? .semibold : .regular))
                    .foregroundStyle(textColor)
                    .frame(width: 28, height: 28)
                    .background {
                        if isSelected {
                            Circle().fill(.tint)
                        } else if isToday {
                            Circle().strokeBorder(.tint, lineWidth: 1.5)
                        }
                    }
                    .padding(.top, 4)

                HStack(spacing: 3) {
                    let sources = dedupedSources()
                    ForEach(sources, id: \.self) { src in
                        Circle()
                            .fill(Self.color(for: src))
                            .frame(width: 5, height: 5)
                    }
                }
                .frame(height: 8)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            .frame(height: cellHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            Text(String(
                format: String(localized: "a11y_calendar_day"),
                accessibleDateString,
                events.count
            ))
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var textColor: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        if isToday { return AnyShapeStyle(.tint) }
        return AnyShapeStyle(.primary)
    }

    private func dedupedSources() -> [AssignmentStore.CalendarEventSource] {
        let order: [AssignmentStore.CalendarEventSource] = [.moodle, .school, .exam, .holiday, .semester]
        var seen = Set<AssignmentStore.CalendarEventSource>()
        var result: [AssignmentStore.CalendarEventSource] = []
        for src in events.map(\.source) where !seen.contains(src) {
            seen.insert(src)
            result.append(src)
        }
        return order.filter { result.contains($0) }.prefix(3).map { $0 }
    }

    static func color(for source: AssignmentStore.CalendarEventSource) -> Color {
        switch source {
        case .moodle: return .blue
        case .school: return .orange
        case .exam: return .red
        case .holiday: return .green
        case .semester: return .indigo
        }
    }
}
#endif
