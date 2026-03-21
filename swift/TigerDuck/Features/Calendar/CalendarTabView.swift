import SwiftUI

struct CalendarTabView: View {
    @State private var viewModel = CalendarViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    HStack {
                        Text("行事曆")
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.md)

                    MonthCalendarView(viewModel: viewModel)

                    Divider().background(Color.textSecondary)
                        .padding(.horizontal)

                    DayEventListView(
                        date: viewModel.selectedDate,
                        events: viewModel.eventsForSelectedDate
                    )
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .onAppear {
            viewModel.load()
        }
    }
}

