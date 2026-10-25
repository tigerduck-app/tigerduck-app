import Defaults
import SwiftUI

struct HomeView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.hostWindow) private var hostWindow
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var showNotImplementedAlert = false
    @State private var selectedFeature: AppFeature?
    @State private var scrollAnchor = HomeScrollAnchor()
    /// The section the page being opened scrolls to.
    @State private var scrollTarget: String?

    @State private var termTicker = MinuteTicker(interval: 60)

    private var visibleSections: [HomeSection] {
        _ = termTicker.tick
        guard !AcademicCalendarStore.shared.calendar.isInSession() else { return viewModel.sections }
        return viewModel.sections.filter { $0.type != .todayCourses }
    }

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
        let _ = AppClockState.shared.version
        return page
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.isEditingHome {
                    Button { showAddSection = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("home_add_section_title"))
                    Button(String(localized: "action_done")) { setEditing(false) }
                }
            }
        }
        .sheet(isPresented: $showAddSection) {
            AddSectionSheet(viewModel: viewModel)
                .presentationDetents([.medium])
        }
        .notImplementedAlert(isPresented: $showNotImplementedAlert)
        .alert(
            String(localized: "sync_conflict_title"),
            isPresented: AppState.syncConflictAlertIsPresented(Bindable(appState).syncConflicts)
        ) {
            Button(String(localized: "sync_conflict_use_server")) { appState.resolveSyncConflicts(keepLocal: false) }
            Button(String(localized: "sync_conflict_use_local")) { appState.resolveSyncConflicts(keepLocal: true) }
        } message: {
            Text(appState.syncConflictAlertMessage)
        }
        .navigationDestination(item: $selectedFeature) { feature in
            homeDestination(for: feature)
        }
        .navigationDestination(item: $viewModel.shownAssignment) { page in
            MoodleAssignmentView(
                store: page.store, entry: page.entry, courseName: page.courseName,
                policy: appState.visualStylePolicy, accent: appState.accentColor
            )
            .moodleLinkOpening()
        }
        .onChange(of: appState.authService.loginGeneration) {
            viewModel.closeAssignment()
        }
        .onChange(of: appState.pendingDeepLink, initial: true) { _, link in
            guard case .assignment(let id) = link else { return }
            appState.pendingDeepLink = nil
            guard let assignment = DataCache.shared.loadAssignments().first(where: { $0.assignmentId == id }) else { return }
            hostWindow.closePresentations { closedAll in openAssignment(assignment, closingSheet: closedAll) }
        }
        .sheet(item: $viewModel.selectedCourse, onDismiss: viewModel.courseSheetDismissed) { course in
            let slot = viewModel.selectedCourseSlot
            CourseDetailSheet(
                course: course,
                assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                timeRange: slot.map { "\($0.start.timeString) - \($0.end.timeString)" },
                weekday: slot?.date.scheduleWeekday ?? AppClock.now().scheduleWeekday,
                periods: slot?.periods
            )
            .onDisappear { viewModel.selectedCourseSlot = nil }
        }
    }

    /// Browsing is one List, so each assignment row takes the system's `.swipeActions`
    /// (UpcomingAssignmentsView says why); editing is `HomeEditPage`. The page that opens scrolls
    /// to the section the other one showed.
    private var page: some View {
        ScrollViewReader { proxy in
            if viewModel.isEditingHome {
                editingPage
                    .onAppear { restoreScroll(proxy) }
            } else {
                sectionList
                    .onAppear { restoreScroll(proxy) }
            }
        }
    }

    private var editingPage: some View {
        HomeEditPage(viewModel: viewModel, sections: visibleSections, scrollAnchor: scrollAnchor) {
            titleBar
                .padding(.top, TigerDuckTheme.Spacing.md)
                .disabled(true)
        }
    }

    private var sectionList: some View {
        List {
            titleBar
                .homeListRow(top: TigerDuckTheme.Spacing.md)

            if let reauthError = appState.ntustReauthErrorMessage {
                reauthBanner(reauthError)
                    .homeListRow(top: TigerDuckTheme.Spacing.lg)
            }

            ForEach(visibleSections) { section in
                if section.type == .upcomingAssignments {
                    homeSection(section, asListRows: true)
                } else {
                    homeSection(section)
                        .homeListRow(top: TigerDuckTheme.Spacing.lg)
                        .homeScrollAnchor(section.id, in: scrollAnchor)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.bottom, TigerDuckTheme.Spacing.xxl, for: .scrollContent)
        .homeScrollTop(in: scrollAnchor)
        .animation(
            UpcomingAssignmentsView.listChangeAnimation,
            value: viewModel.upcomingAssignments.map(\.assignmentId)
        )
        .refreshable {
            // Fire-and-forget so the UIRefreshControl spinner dismisses on release.
            // `triggerRefresh` coalesces repeated pulls into one in-flight fetch, and
            // the top-right SyncStatusDot shows its status.
            viewModel.triggerRefresh(authService: appState.authService)
            if Defaults[.cloudSyncEnabled] {
                Task { await appState.syncOverridesFromBackend() }
            }
        }
    }

    private func setEditing(_ isEditing: Bool) {
        guard viewModel.isEditingHome != isEditing else { return }
        scrollTarget = scrollAnchor.section(in: visibleSections.map(\.id))
        scrollAnchor.reset()
        withAnimation(reduceMotion ? nil : .smoothSpring) { viewModel.isEditingHome = isEditing }
    }

    private func restoreScroll(_ proxy: ScrollViewProxy) {
        guard let target = scrollTarget else { return }
        scrollTarget = nil
        // The page's rows are laid out once the update that made it appear has finished.
        DispatchQueue.main.async { proxy.scrollTo(target, anchor: .top) }
    }

    private func reauthBanner(_ message: String) -> some View {
        NTUSTReauthErrorBanner(
            message: message,
            onRetry: {
                appState.clearNTUSTReauthError()
                appState.presentNTUSTLogin()
            },
            onDismiss: { appState.clearNTUSTReauthError() }
        )
    }

    private var titleBar: some View {
        HStack {
            Text(AppClock.now().greetingText())
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            HStack(spacing: TigerDuckTheme.Spacing.lg) {
                SyncStatusDot(servers: [.moodle, .backend], lastSynced: .schoolData)
                HeaderMenuButton(accessibilityLabel: String(localized: "home_more_actions")) {
                    Button { setEditing(true) } label: {
                        Label(String(localized: "home_edit"), systemImage: "pencil")
                    }
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
    }

    private func homeSection(_ section: HomeSection, asListRows: Bool = false) -> some View {
        HomeSectionView(
            section: section,
            viewModel: viewModel,
            appState: appState,
            asListRows: asListRows,
            scrollAnchor: scrollAnchor,
            onFeatureTap: { feature in
                if feature.isImplemented {
                    selectedFeature = feature
                } else {
                    showNotImplementedAlert = true
                }
            },
            onOpenAssignment: { openAssignment($0) }
        )
    }

    @ViewBuilder
    private func homeDestination(for feature: AppFeature) -> some View {
        switch feature {
        case .announcements: BulletinsView(embedded: true)
        case .classTable: ClassTableView(embedded: true)
        case .calendar: CalendarTabView(embedded: true)
        case .library: LibraryView(embedded: true)
        case .gpa: ScoreView(embedded: true)
        case .emptyClassroom: EmptyClassroomView(embedded: true)
        default: PlaceholderFeatureView(feature: feature)
        }
    }

    private func openAssignment(_ assignment: SDAssignment, closingSheet: Bool = true) {
        if let context = MoodleCacheContext.signedIn(appState.authService),
           let store = MoodleCourseStore.forAssignment(assignment.assignmentId, context: context),
           let entry = store.assignments.entry(for: assignment) {
            viewModel.show(
                MoodleAssignmentPage(entry: entry, store: store, courseName: assignment.displayCourseName),
                closingSheet: closingSheet
            )
        } else if let url = assignment.moodleDeepLink {
            let web = assignment.moodleWebURL
            Task { await openURL(url, fallback: web) }
        }
    }
}

private struct HomeSectionView: View {
    let section: HomeSection
    let viewModel: HomeViewModel
    let appState: AppState
    var asListRows = false
    let scrollAnchor: HomeScrollAnchor
    var onFeatureTap: ((AppFeature) -> Void)? = nil
    var onOpenAssignment: (SDAssignment) -> Void = { _ in }

    private var filterPicker: some View {
        Picker("", selection: Bindable(viewModel).assignmentFilter) {
            ForEach(viewModel.availableAssignmentFilters, id: \.self) { filter in
                Text(filter.displayName).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
    }

    private var assignmentAccess: NTUSTProtectedAccessState {
        appState.ntustProtectedAccessState(isEmpty: viewModel.upcomingAssignments.isEmpty)
    }

    @ViewBuilder
    private var assignmentPlaceholder: some View {
        if assignmentAccess == .loginRequired {
            LoginRequiredView(
                layout: .section,
                title: String(localized: "common_not_signed_in"),
                message: String(localized: "home_assignments_sign_in_required_message"),
                onPrimary: { appState.presentNTUSTLogin() }
            )
        } else {
            EmptyStateView(
                icon: "checkmark.circle",
                title: String(localized: "home_assignments_all_good"),
                message: assignmentEmptyMessage
            )
        }
    }

    private var assignmentList: some View {
        UpcomingAssignmentsView(
            assignments: viewModel.upcomingAssignments,
            courses: viewModel.allCourses,
            filter: viewModel.assignmentFilter,
            showAbsoluteTime: appState.showAbsoluteAssignmentTime,
            asListRows: asListRows,
            onArchive: {
                viewModel.archiveAssignment($0)
                appState.syncAssignmentOverride(moodleId: $0.assignmentId, status: "archived")
            },
            onMarkComplete: {
                viewModel.markAssignmentAsLocallyCompleted($0)
                appState.syncAssignmentOverride(moodleId: $0.assignmentId, status: "locally_completed")
            },
            onUnarchive: {
                viewModel.unarchiveAssignment($0)
                appState.syncAssignmentOverride(moodleId: $0.assignmentId, status: "none")
            },
            onUndoComplete: {
                viewModel.undoLocallyCompleted($0)
                appState.syncAssignmentOverride(moodleId: $0.assignmentId, status: "none")
            },
            onOpen: onOpenAssignment
        )
    }

    private var assignmentEmptyMessage: String {
        switch viewModel.assignmentFilter {
        case .incomplete:
            return String(localized: "home_assignments_none_incomplete")
        case .all:
            return String(localized: "home_assignments_none")
        case .ignored:
            return String(localized: "home_assignments_no_ignored")
        }
    }

    var body: some View {
        if asListRows {
            SectionHeader(title: section.title)
                .homeListRow(top: TigerDuckTheme.Spacing.lg)
                .homeScrollAnchor(section.id, in: scrollAnchor)
            filterPicker
                .homeListRow(top: TigerDuckTheme.Spacing.sm)
            if assignmentAccess == .content {
                assignmentList
            } else {
                assignmentPlaceholder
                    .homeListRow(top: TigerDuckTheme.Spacing.sm)
            }
        } else {
            stackedBody
        }
    }

    private var stackedBody: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            if section.type != .todayCourses {
                SectionHeader(title: section.title)
            }

            switch section.type {
            case .todayCourses:
                TimeSliderSection(
                    courses: viewModel.allCourses,
                    onSelectCourse: { slot in
                        viewModel.selectedCourseSlot = slot
                        viewModel.selectedCourse = slot.course
                    }
                )
            case .upcomingAssignments:
                filterPicker
                if assignmentAccess == .content {
                    assignmentList
                } else {
                    assignmentPlaceholder
                }
            case .quickWidgets, .custom:
                WidgetGridView(
                    widgets: Binding(
                        get: {
                            viewModel.sections.first(where: { $0.id == section.id })?.widgets ?? []
                        },
                        set: { newWidgets in
                            if let idx = viewModel.sections.firstIndex(where: { $0.id == section.id }) {
                                viewModel.sections[idx].widgets = newWidgets
                            }
                        }
                    ),
                    isEditing: false,
                    dragContainerID: section.id,
                    onTap: { feature in
                        onFeatureTap?(feature)
                    }
                )
            }
        }
    }
}

extension View {
    func homeListRow(top: CGFloat, bottom: CGFloat = 0, horizontal: CGFloat = 0) -> some View {
        listRowInsets(EdgeInsets(top: top, leading: horizontal, bottom: bottom, trailing: horizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
