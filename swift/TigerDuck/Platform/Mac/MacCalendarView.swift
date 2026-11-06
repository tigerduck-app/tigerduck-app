#if os(macOS)
import SwiftUI
import TigerDuckCore

struct MacCalendarView: View {
    @State private var viewModel = CalendarViewModel()

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

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.timeZone = TaipeiTime.timeZone
        return viewModel.displayedMonth.formatted(style)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                monthCard
                MacCalendarDayList(date: viewModel.selectedDate, events: viewModel.eventsForSelectedDate)
            }
            .macReadableContent(maxWidth: MacContentWidth.standard)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.smooth(duration: 0.25)) {
                        viewModel.goToToday()
                    }
                } label: {
                    Text(String(localized: "calendar_today"))
                }
                .help(String(localized: "desktop_action_jump_to_today"))
            }
        }
        .onAppear { viewModel.load { nil } }
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
                    viewModel.previousMonth()
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
                    viewModel.nextMonth()
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
            ForEach(Array(viewModel.calendarDays.enumerated()), id: \.offset) { _, date in
                if let date {
                    MacCalendarDayCell(
                        date: date,
                        isSelected: date.isSameDay(as: viewModel.selectedDate),
                        isToday: date.isToday,
                        events: viewModel.eventsOnDate(date),
                        cellHeight: cellHeight,
                        onTap: {
                            withAnimation(.smooth(duration: 0.18)) {
                                viewModel.selectedDate = date
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
}
#endif
