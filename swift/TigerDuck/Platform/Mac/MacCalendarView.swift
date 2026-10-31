#if os(macOS)
import SwiftUI
import TigerDuckCore

struct MacCalendarView: View {
    @Environment(AppState.self) private var appState

    @State private var selectedDate: Date = Date()
    @State private var displayedMonth: Date = Date()
    @State private var cacheRevision: Int = 0
    @State private var eventsMemo = ViewMemo<Int, [DateComponents: [SDCalendarEvent]]>()

    private let weekdaySymbols: [String] = [
        String(localized: "weekday_sun_short"),
        String(localized: "weekday_mon_short"),
        String(localized: "weekday_tue_short"),
        String(localized: "weekday_wed_short"),
        String(localized: "weekday_thu_short"),
        String(localized: "weekday_fri_short"),
        String(localized: "weekday_sat_short"),
    ]
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
    private let cellHeight: CGFloat = 64

    private var allEvents: [SDCalendarEvent] {
        let cached = AssignmentStore.shared.loadCalendarEvents()
            .filter { $0.source != .holiday && $0.source != .semester }
        return cached + AcademicCalendarStore.shared.calendar.calendarEvents()
    }

    private var eventsByDay: [DateComponents: [SDCalendarEvent]] {
        eventsMemo.value(for: cacheRevision) {
            let cal = TaipeiTime.calendar
            return Dictionary(grouping: allEvents) { event in
                cal.dateComponents([.year, .month, .day], from: event.date)
            }
        }
    }

    private var eventsForSelectedDay: [SDCalendarEvent] {
        events(on: selectedDate).sorted { $0.date < $1.date }
    }

    private var calendarDays: [Date?] {
        Self.buildCalendarDays(for: displayedMonth)
    }

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.timeZone = TaipeiTime.timeZone
        return displayedMonth.formatted(style)
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
                        displayedMonth = Date()
                    }
                } label: {
                    Text(String(localized: "calendar_today"))
                }
                .help(String(localized: "desktop_action_jump_to_today"))
            }
        }
        .onChange(of: AppDataRevision.current) {
            cacheRevision &+= 1
        }
    }

    private var monthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            monthNavRow
            weekdayRow
            daysGrid
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

    private var monthNavRow: some View {
        HStack {
            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    displayedMonth = TaipeiTime.calendar.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.leftArrow, modifiers: .command)

            Spacer()

            Text(monthTitle)
                .font(.title3.weight(.semibold))

            Spacer()

            Button {
                withAnimation(.smooth(duration: 0.2)) {
                    displayedMonth = TaipeiTime.calendar.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.rightArrow, modifiers: .command)
        }
    }

    private var weekdayRow: some View {
        LazyVGrid(columns: columns, spacing: 4) {
            ForEach(weekdaySymbols, id: \.self) { symbol in
                Text(symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var daysGrid: some View {
        LazyVGrid(columns: columns, spacing: 6) {
            ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                if let date {
                    DayCell(
                        date: date,
                        isSelected: date.isSameDay(as: selectedDate),
                        isToday: date.isToday,
                        events: events(on: date),
                        cellHeight: cellHeight,
                        onTap: {
                            withAnimation(.smooth(duration: 0.18)) {
                                selectedDate = date
                            }
                        }
                    )
                } else {
                    Color.clear
                        .frame(height: cellHeight)
                }
            }
        }
    }

    private var dayCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(selectedDate, format: .dateTime.weekday(.wide).month(.wide).day())
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)

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
            Text(String(localized: "calendar_no_events_today"))
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

    private func events(on date: Date) -> [SDCalendarEvent] {
        let key = TaipeiTime.calendar.dateComponents([.year, .month, .day], from: date)
        return eventsByDay[key] ?? []
    }

    private func macColor(for source: EventSource) -> Color {
        switch source {
        case .moodle: return .blue
        case .school: return .orange
        case .exam: return .red
        case .holiday: return .green
        case .semester: return .indigo
        }
    }

    private func sourceLabel(_ source: EventSource) -> String {
        switch source {
        case .moodle: String(localized: "calendar_source_moodle")
        case .school: String(localized: "calendar_source_school")
        case .exam: String(localized: "calendar_source_exam")
        case .holiday: String(localized: "calendar_source_holiday")
        case .semester: String(localized: "calendar_source_semester")
        }
    }

    private static func buildCalendarDays(for month: Date) -> [Date?] {
        let cal = TaipeiTime.calendar
        let start = month.startOfMonth
        let daysInMonth = month.daysInMonth
        let firstWeekday = month.firstWeekdayOfMonth

        var days: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in 1...daysInMonth {
            var components = cal.dateComponents([.year, .month], from: start)
            components.day = day
            days.append(cal.date(from: components))
        }
        while days.count % 7 != 0 { days.append(nil) }
        return days
    }
}

private struct DayCell: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let events: [SDCalendarEvent]
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
                            .fill(color(for: src))
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

    private func dedupedSources() -> [EventSource] {
        let order: [EventSource] = [.moodle, .school, .exam, .holiday, .semester]
        var seen = Set<EventSource>()
        var result: [EventSource] = []
        for src in events.map(\.source) where !seen.contains(src) {
            seen.insert(src)
            result.append(src)
        }
        return order.filter { result.contains($0) }.prefix(3).map { $0 }
    }

    private func color(for source: EventSource) -> Color {
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
