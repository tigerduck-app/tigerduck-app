import SwiftUI
import UIKit

struct CalendarTabView: View {
    var embedded = false

    @Environment(AppEnvironment.self) private var app
    @Environment(\.openURL) private var openURL
    @State private var viewModel = CalendarViewModel()
    @State private var shownAssignment: MoodleAssignmentPage?

    private var pageAccessState: NTUSTProtectedAccessState {
        NTUSTProtectedAccessState(signedIn: app.authService.hasStoredCredentials, isEmpty: false)
    }

    var body: some View {
        if embedded {
            gatedContent
        } else {
            NavigationStack { gatedContent }
        }
    }

    private var gatedContent: some View {
        content
            .onChange(of: pageAccessState, initial: true) { _, state in
                guard state != .loginRequired else { return }
                viewModel.load { MoodleCacheContext.signedIn(app.authService, for: app.authService.session.currentSignIn) }
            }
            .moodleAssignmentDestination(
                $shownAssignment, signIn: app.authService.session.currentSignIn, preferences: app.preferences
            )
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
                            onPrimary: { app.router.presentNTUSTLogin() }
                        )
                    case .empty, .content:
                        MonthCalendarView(viewModel: viewModel)

                        Divider().background(Color.textSecondary)
                            .padding(.horizontal)

                        DayEventListView(
                            date: viewModel.selectedDate,
                            events: viewModel.eventsForSelectedDate,
                            assignment: { viewModel.assignment(for: $0) },
                            onOpen: { assignment in
                                MoodleAssignmentPage.open(assignment, authService: app.authService, openURL: openURL) {
                                    shownAssignment = $0
                                }
                            }
                        )
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .refreshable {
                viewModel.triggerRefresh(authService: app.authService)
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
            SyncStatusDot(servers: [.moodle, .backend], lastSynced: .schoolData)
            Button {
                withAnimation(UIAccessibility.isReduceMotionEnabled ? nil : .smoothSpring) {
                    viewModel.goToToday()
                }
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
