import SwiftUI

struct CalendarTabView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = CalendarViewModel()

    /// The calendar sits behind the NTUST sign-in like the class table and
    /// scores: without an account there are no Moodle deadlines to place and no
    /// semester to mark, and a bare month grid is a date picker, not a feature.
    /// Unlike those two it has no separate empty state, since an account with
    /// nothing due still gets the grid, so `isEmpty: false` leaves signed in
    /// versus signed out as the only distinction that matters.
    private var pageAccessState: NTUSTProtectedAccessState {
        appState.ntustProtectedAccessState(isEmpty: false)
    }

    var body: some View {
        if embedded {
            gatedContent
        } else {
            NavigationStack { gatedContent }
        }
    }

    /// Signed out, the page shows only the sign-in wall, so the load waits for an account.
    /// `load` is idempotent, so re-firing it on the sign-in transition fills the screen.
    private var gatedContent: some View {
        content
            .onChange(of: pageAccessState, initial: true) { _, state in
                guard state != .loginRequired else { return }
                viewModel.load(authService: appState.authService)
            }
    }

    private var content: some View {
        ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    titleBar

                    switch pageAccessState {
                    case .loginRequired:
                        LoginRequiredView(
                            layout: .page,
                            title: String(localized: "common_not_signed_in"),
                            message: String(localized: "common_sign_in_required_feature"),
                            onPrimary: { appState.presentNTUSTLogin() }
                        )
                    case .empty, .content:
                        MonthCalendarView(viewModel: viewModel)

                        Divider().background(Color.textSecondary)
                            .padding(.horizontal)

                        DayEventListView(
                            date: viewModel.selectedDate,
                            events: viewModel.eventsForSelectedDate
                        )
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .refreshable {
                viewModel.triggerRefresh(authService: appState.authService)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
    }

    private var titleBar: some View {
        HStack {
            Text(String(localized: "feature_calendar"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            // TigerSync as well as Moodle: deadlines are Moodle's, but holidays and
            // term boundaries come from the backend's academic calendar, so an
            // unreachable backend means rows missing from this screen.
            SyncStatusDot(servers: [.moodle, .backend], lastSynced: .schoolData)
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
    }
}
