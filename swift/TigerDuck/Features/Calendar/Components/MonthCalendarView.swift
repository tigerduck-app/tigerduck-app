import SwiftUI
import TigerDuckCore

struct MonthCalendarView: View {
    let viewModel: CalendarViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var page: Int
    @State private var position: PagerPosition
    @State private var weeks: Int

    init(viewModel: CalendarViewModel) {
        self.viewModel = viewModel
        let page = CalendarViewModel.monthPage(of: viewModel.displayedMonth)
        _page = State(initialValue: page)
        _position = State(initialValue: PagerPosition(page: page))
        _weeks = State(initialValue: Self.weeks(onPage: page))
    }

    private var monthTitle: String {
        var style = Date.FormatStyle.dateTime.year().month(.wide)
        style.timeZone = TaipeiTime.timeZone
        return viewModel.displayedMonth.formatted(style)
    }

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.md) {
            HStack {
                Button { turn(to: position.settledPage - 1) } label: {
                    Image(systemName: "chevron.left")
                        .foregroundStyle(.tint)
                }
                .accessibilityLabel(String(localized: "a11y_calendar_nav_prev"))
                Spacer()
                Text(monthTitle)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                Spacer()
                Button { turn(to: position.settledPage + 1) } label: {
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.tint)
                }
                .accessibilityLabel(String(localized: "a11y_calendar_nav_next"))
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)

            WeekdayRow()

            MonthGrid(days: Array(repeating: nil, count: 7 * weeks), viewModel: viewModel)
                .hidden()
                .overlay(alignment: .top) {
                    Pager(count: CalendarViewModel.monthPageCount, index: $page, position: $position) { page in
                        MonthGrid(days: CalendarViewModel.buildCalendarDays(for: CalendarViewModel.month(atPage: page)), viewModel: viewModel)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .modifier(ScrollStatus(text: monthTitle))
                    // An animated height stops VoiceOver's page scroll partway, so the pager takes its
                    // new height at once and only the views around it animate.
                    .transaction(value: weeks) { $0.animation = nil }
                }
        }
        .onChange(of: page) { _, page in
            viewModel.displayedMonth = CalendarViewModel.month(atPage: page)
        }
        .onChange(of: viewModel.displayedMonth) { _, month in
            let target = CalendarViewModel.monthPage(of: month)
            if target != page { turn(to: target) }
        }
        .onChange(of: position.visiblePages) { _, pages in
            let tallest = pages.map(Self.weeks(onPage:)).max() ?? weeks
            withAnimation(reduceMotion ? nil : .smoothSpring) { weeks = tallest }
        }
    }

    /// The pager builds only the pages beside the current one, so a turn past the next month jumps.
    private func turn(to target: Int) {
        guard (0..<CalendarViewModel.monthPageCount).contains(target) else { return }
        let isNextDoor = abs(target - position.settledPage) == 1
        withAnimation(isNextDoor && !reduceMotion ? .pageTurn : nil) {
            position.go(to: target)
        }
    }

    private static func weeks(onPage page: Int) -> Int {
        CalendarViewModel.buildCalendarDays(for: CalendarViewModel.month(atPage: page)).count / 7
    }
}

private struct MonthGrid: View {
    let days: [Date?]
    let viewModel: CalendarViewModel

    static let columns = Array(repeating: GridItem(.flexible()), count: 7)

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(Array(days.enumerated()), id: \.offset) { _, date in
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

private struct ScrollStatus: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.accessibilityScrollStatus(text)
        } else {
            content
        }
    }
}

private struct WeekdayRow: View {
    private let symbols = [
        String(localized: "weekday_sun_short"),
        String(localized: "weekday_mon_short"),
        String(localized: "weekday_tue_short"),
        String(localized: "weekday_wed_short"),
        String(localized: "weekday_thu_short"),
        String(localized: "weekday_fri_short"),
        String(localized: "weekday_sat_short"),
    ]

    var body: some View {
        LazyVGrid(columns: MonthGrid.columns, spacing: TigerDuckTheme.Spacing.sm) {
            ForEach(symbols, id: \.self) { symbol in
                Text(symbol)
                    .font(TigerDuckTheme.Typography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.3)
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }
}

private struct DayCellView: View {
    let date: Date
    let isSelected: Bool
    let isToday: Bool
    let events: [AssignmentStore.CalendarEvent]
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
            VStack(spacing: 2) {
                Text("\(TaipeiTime.calendar.component(.day, from: date))")
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.white) : isToday ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.textPrimary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.4)
                    .frame(minWidth: 32, minHeight: 32)
                    .background {
                        if isSelected {
                            Circle().fill(.tint)
                        } else if isToday {
                            Circle().stroke(.tint, lineWidth: 1.5)
                        }
                    }

                HStack(spacing: 2) {
                    let sourceOrder: [String] = ["moodle", "school", "exam"]
                    let sources = events.map(\.sourceRaw)
                        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
                        .sorted { (sourceOrder.firstIndex(of: $0) ?? 99) < (sourceOrder.firstIndex(of: $1) ?? 99) }
                        .prefix(3)
                    ForEach(sources, id: \.self) { sourceRaw in
                        Circle()
                            .fill((AssignmentStore.CalendarEventSource(rawValue: sourceRaw) ?? .school).color)
                            .frame(width: 4, height: 4)
                    }
                }
                .frame(height: 6)
            }
        }
        .buttonStyle(.plain)
        .frame(height: 40)
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
}
