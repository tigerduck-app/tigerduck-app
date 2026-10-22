import SwiftUI

struct EmptyClassroomView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel = EmptyClassroomViewModel()
    @State private var wasInBackground = false

    var body: some View {
        if embedded {
            content
        } else {
            NavigationStack { content }
        }
    }

    private var content: some View {
        let access = appState.ntustProtectedAccessState(isEmpty: false)
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                EmptyClassroomTitleBar(viewModel: viewModel, showsStatus: access != .loginRequired)
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
                switch access {
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
                        onRoom: { viewModel.open(room: $0) }
                    )
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
        }
        .scrollIndicators(.hidden)
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .refreshable { await viewModel.refresh() }
        .sheet(item: openRoom) { room in
            EmptyClassroomContent.sheet(for: room, viewModel: viewModel, policy: appState.visualStylePolicy)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
        .onAppear {
            viewModel.connect(appState.authService)
            viewModel.appear()
        }
        .onDisappear { viewModel.disappear() }
        // A glance at Control Center goes inactive and back; only a stay in the background lets
        // the day's rooms age.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { wasInBackground = true }
            guard phase == .active, wasInBackground else { return }
            wasInBackground = false
            viewModel.returnToApp()
        }
        .onChange(of: appState.authService.loginGeneration) { viewModel.accountChanged() }
        .onChange(of: appState.authService.hasStoredCredentials) { viewModel.accountChanged() }
        .onReceive(NotificationCenter.default.publisher(for: AppConstants.dataDidUpdate)) { _ in
            viewModel.dataDidUpdate()
        }
    }

    private var openRoom: Binding<RoomUsage?> {
        let room = viewModel.openRoom
        return Binding(get: { room }, set: { if $0 == nil { viewModel.closeRoom() } })
    }
}

struct EmptyClassroomTitleBar: View {
    let viewModel: EmptyClassroomViewModel
    let showsStatus: Bool

    var body: some View {
        HStack {
            Text(String(localized: "feature_empty_classroom"))
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            if showsStatus {
                SyncStatusDot(
                    status: viewModel.siteStatus,
                    label: String(localized: "feature_empty_classroom"),
                    icon: AppFeature.emptyClassroom.iconName,
                    text: SyncStatusDot.statusText(viewModel.siteStatus),
                    isLoading: viewModel.isReading,
                    lastSynced: viewModel.syncedAt.map { SyncStatusDot.LastSynced.at($0) } ?? .hidden
                )
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }
}

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
