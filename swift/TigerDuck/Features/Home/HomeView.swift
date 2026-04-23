import SwiftUI

struct HomeView: View {
    private static let sectionDragContainerID = "home-sections"

    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var showNotImplementedAlert = false
    @State private var selectedFeature: AppFeature?
    @State private var activeSectionDrag: ReorderDragPayload?
    @State private var didReorderSection = false

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
                // Greeting
                HStack {
                    Text(Date().greetingText())
                        .font(TigerDuckTheme.Typography.title)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
                }
                .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                .padding(.top, TigerDuckTheme.Spacing.md)

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

                // Sections
                ForEach(viewModel.sections) { section in
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
            .onLongPressGesture {
                if !viewModel.isEditingHome {
                    withAnimation(.smoothSpring) {
                        viewModel.isEditingHome = true
                    }
                }
            }
        }
        .refreshable {
            // Fire-and-forget: the pull gesture should dismiss the
            // UIRefreshControl spinner immediately once released.
            // `triggerRefresh` coalesces rapid repeated pulls into a
            // single in-flight fetch; status lives in the top-right
            // NetworkStatusOverlay.
            viewModel.triggerRefresh(authService: appState.authService)
        }
        .background(Color.backgroundPrimary)
        .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if viewModel.isEditingHome {
                    if #available(iOS 26, *) {
                        Button { showAddSection = true } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .frame(width: 28, height: 28)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                    } else {
                        Button { showAddSection = true } label: {
                            Image(systemName: "plus")
                        }
                    }
                    Button("完成") {
                        withAnimation(.smoothSpring) {
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
        .navigationDestination(item: $selectedFeature) { feature in
            homeDestination(for: feature)
        }
        .sheet(item: $viewModel.selectedCourse) { course in
            CourseDetailSheet(
                course: course,
                assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                weekday: Date().scheduleWeekday
            )
            .presentationDetents([.medium, .large])
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

    // MARK: - Section cell

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
        HomeSectionView(
            section: section,
            viewModel: viewModel,
            appState: appState,
            onFeatureTap: { feature in
                if feature.isImplemented {
                    selectedFeature = feature
                } else {
                    showNotImplementedAlert = true
                }
            }
        )
        .overlay(alignment: .top) {
            if viewModel.isEditingHome {
                SectionDragHandle()
            }
        }
        .overlay(alignment: .topTrailing) {
            if viewModel.isEditingHome {
                Button {
                    withAnimation(.smoothSpring) {
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
        .wiggling(viewModel.isEditingHome)
        .opacity(activeSectionDrag?.id == section.id ? 0.35 : 1)
    }

    @ViewBuilder
    private func homeDestination(for feature: AppFeature) -> some View {
        switch feature {
        case .announcements: AnnouncementsView(embedded: true)
        case .classTable: ClassTableView(embedded: true)
        case .calendar: CalendarTabView(embedded: true)
        case .library: LibraryView(embedded: true)
        case .gpa: ScoreView(embedded: true)
        default: PlaceholderFeatureView(feature: feature)
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

// MARK: - Drag handle indicator

private struct SectionDragHandle: View {
    var body: some View {
        HStack(spacing: TigerDuckTheme.Spacing.xs) {
            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.bold))
            Text("長按拖曳排序")
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
                .foregroundStyle(Color.accentPrimary)
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

// MARK: - Section content renderer

private struct HomeSectionView: View {
    let section: HomeSection
    let viewModel: HomeViewModel
    let appState: AppState
    var onFeatureTap: ((AppFeature) -> Void)? = nil

    @ViewBuilder
    private var upcomingAssignmentsContent: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Picker("", selection: Bindable(viewModel).assignmentFilter) {
                ForEach(AssignmentFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .disabled(viewModel.isEditingHome)

            switch appState.ntustProtectedAccessState(isEmpty: viewModel.upcomingAssignments.isEmpty) {
            case .loginRequired:
                LoginRequiredView(
                    layout: .section,
                    title: "尚未登入",
                    message: "尚未登入，無法顯示作業",
                    onPrimary: { appState.presentNTUSTLogin() }
                )
            case .empty:
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: "一切順利",
                    message: viewModel.assignmentFilter == .incomplete ? "沒有未完成的作業" : "沒有作業"
                )
            case .content:
                UpcomingAssignmentsView(
                    assignments: viewModel.upcomingAssignments,
                    showAbsoluteTime: appState.showAbsoluteAssignmentTime,
                    onArchive: { viewModel.archiveAssignment($0) },
                    onMarkComplete: { viewModel.markAssignmentAsLocallyCompleted($0) },
                    onUnarchive: { viewModel.unarchiveAssignment($0) },
                    onUndoComplete: { viewModel.undoLocallyCompleted($0) }
                )
                .allowsHitTesting(!viewModel.isEditingHome)
            }
        }
    }

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            if section.type != .todayCourses {
                SectionHeader(title: section.title)
            }

            switch section.type {
            case .todayCourses:
                TimeSliderSection(
                    courses: viewModel.allCourses,
                    onSelectCourse: { course in
                        guard !viewModel.isEditingHome else { return }
                        viewModel.selectedCourse = course
                    }
                )
            case .upcomingAssignments:
                upcomingAssignmentsContent
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
                    isEditing: Binding(
                        get: { viewModel.isEditingHome },
                        set: { viewModel.isEditingHome = $0 }
                    ),
                    dragContainerID: section.id,
                    onRemove: { widget in
                        withAnimation(.smoothSpring) {
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
