import SwiftUI

struct MonthCalendarView: View {
    @Bindable var viewModel: CalendarViewModel

    private let weekdaySymbols = [
        String(localized: "weekday_sun_short"),
        String(localized: "weekday_mon_short"),
        String(localized: "weekday_tue_short"),
        String(localized: "weekday_wed_short"),
        String(localized: "weekday_thu_short"),
        String(localized: "weekday_fri_short"),
        String(localized: "weekday_sat_short"),
    ]
    private let columns = Array(repeating: GridItem(.flexible()), count: 7)

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.timeZone = AppConstants.taipeiTimeZone
        return viewModel.displayedMonth.formatted(style)
    }

    private var calendarDays: [Date?] { viewModel.calendarDays }

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            // Month navigation
            HStack {
                Button(action: viewModel.previousMonth) {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(Color.accentPrimary)
                }
                Spacer()
                Text(monthTitle)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer()
                Button(action: viewModel.nextMonth) {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Color.accentPrimary)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            // Weekday header
            LazyVGrid(columns: columns, spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(TigerDuckTheme.Typography.caption)
                        .foregroundStyle(Color.textSecondary)
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            // Days grid
            LazyVGrid(columns: columns, spacing: TigerDuckTheme.Spacing.sm) {
                ForEach(Array(calendarDays.enumerated()), id: \.offset) { _, date in
                    if let date {
                        DayCellView(
                            date: date,
                            isSelected: date.isSameDay(as: viewModel.selectedDate),
                            isToday: date.isToday,
                            events: viewModel.eventsOnDate(date)
                        ) {
                            viewModel.selectedDate = date
                        }
                    } else {
                        Color.clear
                            .frame(height: 40)
                    }
                }
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        }
    }
}

private struct DayCellView: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let events: [SDCalendarEvent]
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 2) {
                Text("\(AppConstants.taipeiCalendar.component(.day, from: date))")
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(isSelected ? .white : (isToday ? .accentPrimary : .textPrimary))
                    .frame(width: 32, height: 32)
                    .background {
                        if isSelected {
                            Circle().fill(Color.accentPrimary)
                        } else if isToday {
                            Circle().stroke(Color.accentPrimary, lineWidth: 1.5)
                        }
                    }

                // Event dots
                HStack(spacing: 2) {
                    let sourceOrder: [String] = ["moodle", "school", "exam"]
                    let sources = events.map(\.sourceRaw)
                        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        .sorted { (sourceOrder.firstIndex(of: $0) ?? 99) < (sourceOrder.firstIndex(of: $1) ?? 99) }
                        .prefix(3)
                    ForEach(sources, id: \.self) { sourceRaw in
                        Circle()
                            .fill((EventSource(rawValue: sourceRaw) ?? .school).color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 6)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 40)
    }
}
