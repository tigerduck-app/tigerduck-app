#if os(macOS)
import SwiftUI

/// macOS Calendar surface.
///
/// Uses the system-native `DatePicker(.graphical)` month grid for the
/// month UI — it ships with macOS's familiar look (chevron month nav,
/// keyboard arrows, today highlight) and stays consistent with the OS
/// without us reimplementing a custom grid. Below the picker sits a
/// day-events panel that lists every cached school + Moodle event for
/// the selected date (similar to the iPhone CalendarTabView, but the
/// per-day event-dot indicators that the iPhone grid drew aren't
/// available on the system calendar — the trade-off for native chrome.)
///
/// Source-of-truth is `DataCache.loadCalendarEvents()` (populated by
/// `appState.backgroundSync()`). EventKit overlay (system Calendar
/// events) and notifications are deliberately out of scope on Mac.
struct MacCalendarView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedDate: Date = Date()

    private var allEvents: [SDCalendarEvent] {
        DataCache.shared.loadCalendarEvents()
            .sorted { $0.date < $1.date }
    }

    private var eventsByDay: [DateComponents: [SDCalendarEvent]] {
        let cal = AppConstants.taipeiCalendar
        return Dictionary(grouping: allEvents) { event in
            cal.dateComponents([.year, .month, .day], from: event.date)
        }
    }

    private var eventsForSelectedDay: [SDCalendarEvent] {
        events(on: selectedDate)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                monthCard
                dayCard
            }
            .macReadableContent(maxWidth: MacContentWidth.standard)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        selectedDate = Date()
                    }
                } label: {
                    Label("Today", systemImage: "circle.fill")
                }
                .help("Jump to today")
            }
        }
    }

    // MARK: - Month picker card

    private var monthCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            DatePicker(
                "Select a date",
                selection: $selectedDate,
                displayedComponents: [.date]
            )
            .datePickerStyle(.graphical)
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 0.5)
        )
    }

    // MARK: - Selected day events

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedDate, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.headline)
                Spacer()
                Text("\(eventsForSelectedDay.count) event\(eventsForSelectedDay.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if eventsForSelectedDay.isEmpty {
                emptyDayState
            } else {
                VStack(spacing: 6) {
                    ForEach(eventsForSelectedDay, id: \.eventId) { event in
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
            Text("Nothing on this day")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 100)
    }

    private func eventRow(_ event: SDCalendarEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(macColor(for: event.source))
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
            Text(event.date, style: .time)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(.background.tertiary)
        )
    }

    // MARK: - Helpers

    private func events(on date: Date) -> [SDCalendarEvent] {
        let key = AppConstants.taipeiCalendar.dateComponents([.year, .month, .day], from: date)
        return (eventsByDay[key] ?? []).sorted { $0.date < $1.date }
    }

    private func macColor(for source: EventSource) -> Color {
        switch source {
        case .moodle: return .blue
        case .school: return .orange
        case .exam: return .red
        case .system: return .gray
        }
    }

    private func sourceLabel(_ source: EventSource) -> String {
        switch source {
        case .moodle: "Moodle assignment"
        case .school: "NTUST academic calendar"
        case .exam: "Exam"
        case .system: "System calendar"
        }
    }
}
#endif
