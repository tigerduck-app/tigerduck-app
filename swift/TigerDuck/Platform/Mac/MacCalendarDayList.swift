#if os(macOS)
import SwiftUI

struct MacCalendarDayList: View {
    let date: Date
    let events: [AssignmentStore.CalendarEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(date, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

            if events.isEmpty {
                emptyDayState
            } else {
                VStack(spacing: 6) {
                    ForEach(events, id: \.eventId) { event in
                        eventRow(event)
                    }
                }
            }
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .fill(.background.secondary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    private var emptyDayState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(String(localized: "calendar_no_events_today"))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func eventRow(_ event: AssignmentStore.CalendarEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(MacCalendarDayCell.color(for: event.source))
                .frame(width: 8, height: 8)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title)
                    .font(.body)
                Text(sourceLabel(event.source))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if !event.isAllDay {
                Text(event.date, style: .time)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    private func sourceLabel(_ source: AssignmentStore.CalendarEventSource) -> String {
        switch source {
        case .moodle: String(localized: "calendar_source_moodle")
        case .school: String(localized: "calendar_source_school")
        case .exam: String(localized: "calendar_source_exam")
        case .holiday: String(localized: "calendar_source_holiday")
        case .semester: String(localized: "calendar_source_semester")
        }
    }
}
#endif
