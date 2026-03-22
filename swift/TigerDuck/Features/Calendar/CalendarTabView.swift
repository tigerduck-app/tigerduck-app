import SwiftUI

struct CalendarTabView: View {
    @Environment(AppState.self) private var appState
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
                        NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
                        Button {
                            viewModel.goToToday()
                        } label: {
                            Text("今天")
                                .font(TigerDuckTheme.Typography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
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
            .refreshable {
                await viewModel.refresh(authService: appState.authService)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        }
        .onAppear {
            viewModel.load(authService: appState.authService)
        }
    }
}
