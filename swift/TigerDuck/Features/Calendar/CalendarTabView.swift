import SwiftUI

struct CalendarTabView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = CalendarViewModel()

    /// The calendar is a 校務系統-protected surface like the class table and
    /// scores: without an account there are no Moodle deadlines to place and
    /// no semester to mark, and a bare month grid is a date picker, not a
    /// feature. Unlike those two it has no separate empty state — an account
    /// with nothing due still gets the grid — so `isEmpty: false` leaves the
    /// signed-in / signed-out distinction as the only one that matters.
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

    /// Holding the load until there is an account keeps the EventKit
    /// permission prompt off a screen that is showing a sign-in wall —
    /// asking for the device calendar to populate a grid the user cannot
    /// see would be a bad trade for them and a poor look for us. `load` is
    /// idempotent, so re-firing it on the sign-in transition is what
    /// actually fills the screen once the user gets an account.
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
            // TigerSync as well as Moodle: the deadlines are Moodle's, but the
            // holidays and term boundaries on this screen come from the
            // backend's published academic calendar, so a backend the app
            // cannot reach is a source this screen is missing rows from.
            SyncStatusDot(servers: [.moodle, .backend])
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
