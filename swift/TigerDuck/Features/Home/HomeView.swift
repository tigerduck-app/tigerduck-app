import Defaults
import SwiftUI

struct HomeView: View {
    private static let sectionDragContainerID = "home-sections"

    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openURL) private var openURL
    @Environment(\.hostWindow) private var hostWindow
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var showNotImplementedAlert = false
    @State private var selectedFeature: AppFeature?
    @State private var activeSectionDrag: ReorderDragPayload?
    @State private var didReorderSection = false

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
        .refreshable {
            // Fire-and-forget so the UIRefreshControl spinner dismisses on release.
            // `triggerRefresh` coalesces repeated pulls into one in-flight fetch, and
            // the top-right SyncStatusDot shows its status.
            viewModel.triggerRefresh(authService: appState.authService)
            if Defaults[.cloudSyncEnabled] {
                Task { await appState.syncOverridesFromBackend() }
            }
        }
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.isEditingHome {
                    Button { showAddSection = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel(Text("home_add_section_title"))
                    Button(String(localized: "action_done")) {
                        withAnimation(reduceMotion ? nil : .smoothSpring) {
                            finishSectionDrag()
                            viewModel.isEditingHome = false
                        }
                    }
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
        .onChange(of: viewModel.isEditingHome) { _, isEditing in
            if !isEditing {
                finishSectionDrag()
            }
        }
        .onDisappear {
            finishSectionDrag()
        }
    }

    /// Browsing is one List, so each assignment row takes the system's `.swipeActions`
    /// (UpcomingAssignmentsView says why). Editing is a stack: in a List row SwiftUI hands every
    /// `.draggable` to the List, which then drags the row's first widget wherever the press lands,
    /// and `onMove` reorders only from the grip of the system edit mode.
    @ViewBuilder
    private var page: some View {
        if viewModel.isEditingHome {
            editingPage
        } else {
            sectionList
        }
    }

    private var editingPage: some View {
        ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                titleBar
                    .padding(.top, TigerDuckTheme.Spacing.md)

                if let reauthError = appState.ntustReauthErrorMessage {
                    reauthBanner(reauthError)
                }

                ForEach(visibleSections) { section in
                    sectionCell(section)
                }
            }
            .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            .onDrop(
                of: [.tigerDuckReorderPayload],
                delegate: ReorderContainerDropDelegate(
                    expectedKind: .homeSection,
                    containerID: Self.sectionDragContainerID,
                    activePayload: $activeSectionDrag,
                    didReorder: $didReorderSection,
                    onPersist: viewModel.saveSectionLayout
                )
            )
            .contentShape(Rectangle())
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
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .contentMargins(.bottom, TigerDuckTheme.Spacing.xxl, for: .scrollContent)
        .animation(
            UpcomingAssignmentsView.listChangeAnimation,
            value: viewModel.upcomingAssignments.map(\.assignmentId)
        )
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
                    Button {
                        withAnimation(reduceMotion ? nil : .smoothSpring) { viewModel.isEditingHome = true }
                    } label: {
                        Label(String(localized: "home_edit"), systemImage: "pencil")
                    }
                }
                .disabled(viewModel.isEditingHome)
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
    private func sectionCell(_ section: HomeSection) -> some View {
        let content = sectionContent(section)

        if viewModel.isEditingHome {
            let payload = sectionDragPayload(for: section)
            content
                .draggable(payload) {
                    SectionDragPreview(section: section)
                        .onAppear { activeSectionDrag = payload }
                }
                .onDrop(
                    of: [.tigerDuckReorderPayload],
                    delegate: ReorderDropDelegate(
                        targetID: section.id,
                        expectedKind: .homeSection,
                        containerID: Self.sectionDragContainerID,
                        activePayload: $activeSectionDrag,
                        didReorder: $didReorderSection,
                        currentIDs: { viewModel.sections.map(\.id) },
                        moveAction: { fromOffsets, destination in
                            viewModel.sections.move(fromOffsets: fromOffsets, toOffset: destination)
                        },
                        onPersist: viewModel.saveSectionLayout
                    )
                )
        } else {
            content
        }
    }

    @ViewBuilder
    private func sectionContent(_ section: HomeSection) -> some View {
        homeSection(section)
            .overlay(alignment: .top) {
                if viewModel.isEditingHome {
                    SectionDragHandle()
                }
            }
            .overlay(alignment: .topTrailing) {
                if viewModel.isEditingHome {
                    Button {
                        withAnimation(reduceMotion ? nil : .smoothSpring) {
                            viewModel.removeSection(section)
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.white, .red)
                            .font(.title3)
                    }
                    .offset(x: 6, y: -6)
                }
            }
            .opacity(activeSectionDrag?.id == section.id ? 0.35 : 1)
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

    private func sectionDragPayload(for section: HomeSection) -> ReorderDragPayload {
        ReorderDragPayload(
            id: section.id,
            kind: .homeSection,
            containerID: Self.sectionDragContainerID
        )
    }

    private func finishSectionDrag() {
        ReorderDropSupport.finalizeDrop(
            activePayload: $activeSectionDrag,
            didReorder: $didReorderSection,
            onPersist: viewModel.saveSectionLayout
        )
    }
}

private struct SectionDragHandle: View {
    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.bold))
            Text(String(localized: "home_section_drag_hint"))
                .font(TigerDuckTheme.Typography.caption2)
        }
        .foregroundStyle(Color.textSecondary)
        .padding(.horizontal, TigerDuckTheme.Spacing.md)
        .padding(.vertical, TigerDuckTheme.Spacing.xs)
        .background(
            Capsule().fill(Color(.systemGray5))
        )
        .padding(.top, TigerDuckTheme.Spacing.xs)
    }
}

private struct SectionDragPreview: View {
    let section: HomeSection

    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.sm) {
            Image(systemName: section.type.iconName)
                .font(.title3)
                .foregroundStyle(.tint)
            Text(section.title)
                .font(TigerDuckTheme.Typography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(TigerDuckTheme.Spacing.lg)
        .frame(width: 280, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                .fill(Color(.secondarySystemGroupedBackground))
                .shadow(color: .black.opacity(0.18), radius: 10, x: 0, y: 4)
        )
    }
}

private struct HomeSectionView: View {
    let section: HomeSection
    let viewModel: HomeViewModel
    let appState: AppState
    var asListRows = false
    var onFeatureTap: ((AppFeature) -> Void)? = nil
    var onOpenAssignment: (SDAssignment) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filterPicker: some View {
        Picker("", selection: Bindable(viewModel).assignmentFilter) {
            ForEach(viewModel.availableAssignmentFilters, id: \.self) { filter in
                Text(filter.displayName).tag(filter)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal)
        .disabled(viewModel.isEditingHome)
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
                        guard !viewModel.isEditingHome else { return }
                        viewModel.selectedCourseSlot = slot
                        viewModel.selectedCourse = slot.course
                    }
                )
            case .upcomingAssignments:
                filterPicker
                if assignmentAccess == .content {
                    assignmentList
                        .allowsHitTesting(!viewModel.isEditingHome)
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
                    isEditing: viewModel.isEditingHome,
                    dragContainerID: section.id,
                    onRemove: { widget in
                        withAnimation(reduceMotion ? nil : .smoothSpring) {
                            viewModel.removeWidget(from: section.id, widget: widget)
                        }
                    },
                    onTap: { feature in
                        onFeatureTap?(feature)
                    },
                    onReorder: {
                        viewModel.saveSectionLayout()
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
