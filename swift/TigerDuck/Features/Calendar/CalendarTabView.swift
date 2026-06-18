import SwiftUI

struct CalendarTabView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = CalendarViewModel()

    var body: some View {
        if embedded {
            content
                .onAppear { viewModel.load(authService: appState.authService) }
        } else {
            NavigationStack { content }
                .onAppear { viewModel.load(authService: appState.authService) }
        }
    }

    private var content: some View {
        ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    HStack(alignment: .top) {
                        Text(String(localized: "feature_calendar"))
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
                        Button {
                            viewModel.goToToday()
                        } label: {
                            Text(String(localized: "calendar_today"))
                                .font(.caption.weight(.semibold))
                        }
                        .modifier(GlassTextButtonModifier())
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
}
