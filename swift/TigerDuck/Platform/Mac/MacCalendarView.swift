#if os(macOS)
import SwiftUI

/// macOS Calendar surface — chronological grouped list of school +
/// Moodle calendar events.
///
/// Reads directly from `DataCache.loadCalendarEvents()` (populated by
/// `appState.backgroundSync()`) rather than going through the iOS
/// `CalendarViewModel`, which has the EventKit system-calendar overlay
/// and the month-grid UX that doesn't translate cleanly to a Mac
/// sidebar layout. EventKit overlay is a follow-up port — first land a
/// clean list so the Mac user sees the school + Moodle stream.
struct MacCalendarView: View {
    @Environment(AppState.self) private var appState

    @State private var showPastEvents = false

    private var allEvents: [SDCalendarEvent] {
        DataCache.shared.loadCalendarEvents()
            .sorted { $0.date < $1.date }
    }

    private var visibleEvents: [SDCalendarEvent] {
        let now = Date()
        return allEvents.filter {
            showPastEvents || $0.date >= AppConstants.taipeiCalendar.startOfDay(for: now)
        }
    }

    private var groupedByDay: [(day: Date, events: [SDCalendarEvent])] {
        let calendar = AppConstants.taipeiCalendar
        let grouped = Dictionary(grouping: visibleEvents) { event in
            calendar.startOfDay(for: event.date)
        }
        return grouped
            .map { (day: $0.key, events: $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.day < $1.day }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if visibleEvents.isEmpty {
                    emptyState
                } else {
                    ForEach(groupedByDay, id: \.day) { group in
                        daySection(day: group.day, events: group.events)
                    }
                }
            }
            .padding(32)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Toggle(isOn: $showPastEvents) {
                    Label("Show past events", systemImage: "clock.arrow.circlepath")
                }
                .toggleStyle(.switch)
                .help("Include events that have already passed")
            }
        }
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Upcoming")
                    .font(.title2.bold())
                Text(showPastEvents
                     ? "Showing every cached school + Moodle event."
                     : "School + Moodle events from today onward.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.title)
                .foregroundStyle(.secondary)
            Text(showPastEvents ? "No events cached" : "Nothing coming up")
                .font(.headline)
            Text("Sync (⌘R) will refresh from the school ICS feed and Moodle assignment deadlines.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private func daySection(day: Date, events: [SDCalendarEvent]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(day, format: .dateTime.weekday(.wide))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isToday(day) ? Color.accentColor : .primary)
                Text(day, format: .dateTime.month(.abbreviated).day())
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if isToday(day) {
                    Text("Today")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().fill(Color.accentColor.opacity(0.18))
                        )
                        .foregroundStyle(Color.accentColor)
                }
                Spacer()
            }

            VStack(spacing: 6) {
                ForEach(events, id: \.eventId) { event in
                    eventRow(event)
                }
            }
        }
    }

    private func eventRow(_ event: SDCalendarEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Circle()
                .fill(event.source.macColor)
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
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.md, style: .continuous)
                .fill(Color.secondarySystemGroupedBackgroundCompat)
        )
    }

    private func sourceLabel(_ source: EventSource) -> String {
        switch source {
        case .moodle: "Moodle assignment"
        case .school: "NTUST academic calendar"
        case .exam: "Exam"
        case .system: "System calendar"
        }
    }

    private func isToday(_ day: Date) -> Bool {
        AppConstants.taipeiCalendar.isDateInToday(day)
    }
}

private extension EventSource {
    /// Mac-side colour palette for the inline dot indicator. SDCalendarEvent
    /// has its own `color` accessor that resolves through the iOS asset
    /// catalog; using SwiftUI semantic colours here keeps the Mac render
    /// predictable in light + dark mode without adding new catalog sets.
    var macColor: Color {
        switch self {
        case .moodle: return .blue
        case .school: return .orange
        case .exam: return .red
        case .system: return .gray
        }
    }
}
#endif
