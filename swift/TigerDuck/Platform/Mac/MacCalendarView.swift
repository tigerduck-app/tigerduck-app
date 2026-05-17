#if os(macOS)
import SwiftUI

/// macOS Calendar surface — month grid + day-event panel, mirroring
/// the iPhone `CalendarTabView` layout.
///
/// Source-of-truth is `DataCache.loadCalendarEvents()` (populated by
/// `appState.backgroundSync()`). EventKit overlay (system Calendar
/// events) and notifications are deliberately out of scope on Mac.
struct MacCalendarView: View {
    @Environment(AppState.self) private var appState

    @State private var displayedMonth: Date = Date()
    @State private var selectedDate: Date = Date()

    private let weekdaySymbols = [
        String(localized: "weekday_sun_short"),
        String(localized: "weekday_mon_short"),
        String(localized: "weekday_tue_short"),
        String(localized: "weekday_wed_short"),
        String(localized: "weekday_thu_short"),
        String(localized: "weekday_fri_short"),
        String(localized: "weekday_sat_short"),
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

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

    private var calendarDays: [Date?] {
        Self.buildCalendarDays(for: displayedMonth)
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
                        displayedMonth = Date()
                        selectedDate = Date()
                    }
                } label: {
                    Label("Today", systemImage: "circle.fill")
                }
                .help("Jump to today")
            }
        }
    }

    // MARK: - Month grid card

    private var monthCard: some View {
        VStack(spacing: 12) {
            monthNav
            weekdayHeader
            monthGrid
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

    private var monthNav: some View {
        HStack {
            Button {
                shift(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)

            Spacer()

            Text(monthTitle)
                .font(.headline)

            Spacer()

            Button {
                shift(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
        }
    }

    private var weekdayHeader: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var monthGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                if let date {
                    dayCell(date)
                } else {
                    Color.clear.frame(height: 56)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let isSelected = AppConstants.taipeiCalendar.isDate(date, inSameDayAs: selectedDate)
        let isToday = AppConstants.taipeiCalendar.isDateInToday(date)
        let dayEvents = events(on: date)
        return Button {
            withAnimation(.smooth(duration: 0.18)) {
                selectedDate = date
            }
        } label: {
            VStack(spacing: 4) {
                Text("\(AppConstants.taipeiCalendar.component(.day, from: date))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(isSelected ? .white : (isToday ? Color.accentColor : .primary))
                    .frame(width: 28, height: 28)
                    .background(
                        ZStack {
                            if isSelected {
                                Circle().fill(Color.accentColor)
                            } else if isToday {
                                Circle().stroke(Color.accentColor, lineWidth: 1.5)
                            }
                        }
                    )
                HStack(spacing: 3) {
                    let sourceOrder: [EventSource] = [.moodle, .school, .exam]
                    let sources = Array(
                        Set(dayEvents.map(\.source))
                            .sorted { (sourceOrder.firstIndex(of: $0) ?? 99) < (sourceOrder.firstIndex(of: $1) ?? 99) }
                            .prefix(3)
                    )
                    ForEach(sources, id: \.self) { source in
                        Circle()
                            .fill(macColor(for: source))
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 6)
            }
            .frame(maxWidth: .infinity, minHeight: 56)
        }
        .buttonStyle(.plain)
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

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.timeZone = AppConstants.taipeiTimeZone
        return displayedMonth.formatted(style)
    }

    private func events(on date: Date) -> [SDCalendarEvent] {
        let key = AppConstants.taipeiCalendar.dateComponents([.year, .month, .day], from: date)
        return (eventsByDay[key] ?? []).sorted { $0.date < $1.date }
    }

    private func shift(by months: Int) {
        guard let next = AppConstants.taipeiCalendar.date(
            byAdding: .month, value: months, to: displayedMonth
        ) else { return }
        withAnimation(.smooth(duration: 0.25)) {
            displayedMonth = next
        }
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

    /// Build a Sun-first week-aligned grid for the month containing
    /// `date`. Nil slots pad the leading weekdays before the 1st and
    /// the trailing weekdays after the last day so the grid is always
    /// a multiple of 7 cells.
    private static func buildCalendarDays(for month: Date) -> [Date?] {
        let cal = AppConstants.taipeiCalendar
        var components = cal.dateComponents([.year, .month], from: month)
        components.day = 1
        guard let firstOfMonth = cal.date(from: components),
              let range = cal.range(of: .day, in: .month, for: firstOfMonth) else {
            return []
        }
        let firstWeekday = cal.component(.weekday, from: firstOfMonth) // 1 = Sunday
        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in 1...range.count {
            components.day = day
            days.append(cal.date(from: components))
        }
        while days.count % 7 != 0 {
            days.append(nil)
        }
        return days
    }
}
#endif
