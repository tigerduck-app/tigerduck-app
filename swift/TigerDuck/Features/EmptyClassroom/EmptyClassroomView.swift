import SwiftUI

/// More's empty-classroom finder: free rooms on the main campus for a day and period, with a
/// room to wait in between the user's classes.
struct EmptyClassroomView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = EmptyClassroomViewModel()
    @State private var openRoom: RoomUsage?

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let reauthError = appState.ntustReauthErrorMessage {
                    NTUSTReauthErrorBanner(
                        message: reauthError,
                        onRetry: {
                            appState.clearNTUSTReauthError()
                            appState.presentNTUSTLogin()
                        },
                        onDismiss: { appState.clearNTUSTReauthError() }
                    )
                }
                switch appState.ntustProtectedAccessState(isEmpty: false) {
                case .loginRequired:
                    LoginRequiredView(
                        layout: .page,
                        title: String(localized: "common_not_signed_in"),
                        message: String(localized: "common_sign_in_required_feature"),
                        onPrimary: { appState.presentNTUSTLogin() }
                    )
                case .content, .empty:
                    EmptyClassroomContent(
                        viewModel: viewModel,
                        policy: appState.visualStylePolicy,
                        onRoom: { openRoom = $0 }
                    )
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.backgroundPrimary)
        .navigationTitle(String(localized: "feature_empty_classroom"))
        .refreshable { await viewModel.refresh() }
        .sheet(item: $openRoom) { room in
            EmptyClassroomContent.sheet(for: room, viewModel: viewModel, policy: appState.visualStylePolicy)
        }
        .onAppear {
            viewModel.connect(appState.authService)
            viewModel.appear()
        }
        .onDisappear { viewModel.disappear() }
        // A sign-out moves the generation; a sign-in on this screen only stores credentials.
        .onChange(of: appState.authService.loginGeneration) { accountChanged() }
        .onChange(of: appState.authService.hasStoredCredentials) { accountChanged() }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
            viewModel.reloadCourses()
        }
    }

    private func accountChanged() {
        openRoom = nil
        viewModel.accountChanged()
    }
}

/// The finder's screen below the title, from the view model alone, so it can be laid out
/// without the app's state.
struct EmptyClassroomContent: View {
    let viewModel: EmptyClassroomViewModel
    let policy: VisualStylePolicy
    let onRoom: (RoomUsage) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ClassroomTimeBar(
                days: viewModel.days,
                selectedDay: viewModel.selectedDay,
                period: viewModel.selectedPeriod,
                policy: policy,
                label: viewModel.dayLabel,
                onSelect: viewModel.select(day:)
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.md)
            PeriodChipRow(
                selected: viewModel.selectedPeriod,
                current: viewModel.currentPeriod,
                ended: viewModel.endedPeriods,
                policy: policy,
                onSelect: viewModel.select(period:)
            )
            .padding(.top, TigerDuckTheme.Spacing.md)
            dayContent
        }
    }

    @ViewBuilder
    private var dayContent: some View {
        switch viewModel.content {
        case .loading:
            ClassroomSkeleton(policy: policy)
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.top, TigerDuckTheme.Spacing.xl)
        case .failed(let offline):
            ClassroomStateCard(
                systemImage: offline ? "wifi.slash" : "exclamationmark.triangle",
                title: String(localized: "empty_classroom_load_failed"),
                policy: policy
            ) {
                Button(String(localized: "action_retry"), action: viewModel.retry)
                    .font(.subheadline.weight(.semibold))
                    .modifier(GlassTextButtonModifier())
            }
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xl)
        case .noData:
            dayOffCard(title: String(localized: "empty_classroom_no_data"))
        case .holiday(let name):
            dayOffCard(title: name)
        case .rooms:
            rooms
        }
    }

    private func dayOffCard(title: String) -> some View {
        ClassroomStateCard(systemImage: "calendar", title: title, policy: policy) {
            if let next = viewModel.nextTeachingDay {
                NextTeachingDayButton(day: next, onSelect: viewModel.select(day:))
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.xl)
    }

    @ViewBuilder
    private var rooms: some View {
        let suggestion = viewModel.suggestion
        if let suggestion {
            SuggestionSection(
                suggestion: suggestion,
                ended: viewModel.endedPeriods,
                policy: policy,
                onRoom: onRoom
            )
            .padding(.horizontal, TigerDuckTheme.Spacing.lg)
            .padding(.top, TigerDuckTheme.Spacing.xl)
        }
        if let directory = viewModel.directory,
           let shown = viewModel.shownBuilding(in: directory, suggestion: suggestion) {
            let period = viewModel.selectedPeriod
            BuildingSection(
                directory: directory,
                shown: shown,
                period: period,
                ended: viewModel.endedPeriods,
                policy: policy,
                name: viewModel.buildingName,
                onPick: viewModel.pick(building:),
                onNextPeriod: period + 1 < EmptyClassroomSchedule.periodIDs.count
                    ? { viewModel.select(period: period + 1) }
                    : nil,
                onRoom: onRoom
            )
            .padding(.top, TigerDuckTheme.Spacing.xxl)
        }
    }

    /// The building's name as the site gives it, and the room's floor.
    private static func place(of room: RoomUsage, viewModel: EmptyClassroomViewModel) -> String {
        guard let place = RoomPlace(room: room.room) else { return room.room }
        return "\(viewModel.buildingName(place.building)) \(place.floorLabel)"
    }

    static func sheet(for room: RoomUsage, viewModel: EmptyClassroomViewModel, policy: VisualStylePolicy) -> RoomDaySheet {
        RoomDaySheet(
            room: room,
            place: place(of: room, viewModel: viewModel),
            day: EmptyClassroomViewModel.dateText(viewModel.selectedDay),
            period: viewModel.selectedPeriod,
            ended: viewModel.endedPeriods,
            nowPeriod: viewModel.currentPeriod,
            policy: policy
        )
    }
}
