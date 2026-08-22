import Defaults
import SwiftUI

struct HomeView: View {
    private static let sectionDragContainerID = "home-sections"

    var embedded = false

    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var showNotImplementedAlert = false
    @State private var selectedFeature: AppFeature?
    @State private var activeSectionDrag: ReorderDragPayload?
    @State private var didReorderSection = false

    /// Slow pulse so the term gate below flips on its own when wall-clock
    /// time crosses `CurrentTerm.start` / `.end` while Home stays mounted.
    /// `content` already reads `AppClockState.version`, which covers debug
    /// clock overrides, but ordinary time passing invalidates nothing —
    /// `AppClock.now()` is an untracked side-effect as far as Observation is
    /// concerned. Both boundaries land at midnight, so a minute of latency is
    /// ample and 60s keeps this far cheaper than the 5s default the today
    /// carousel needs.
    @State private var termTicker = MinuteTicker(interval: 60)

    /// ponytail: Home's time slider is a "today" surface, so it is dropped
    /// outside the term rather than left to scrub a day with no classes.
    /// Reorder and drag are unaffected — everything downstream keys off
    /// `section.id`, never this array's indices.
    private var visibleSections: [HomeSection] {
        _ = termTicker.tick
        guard !AppConstants.CurrentTerm.isInSession else { return viewModel.sections }
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
        // Touch AppClockState.version so SwiftUI tracks the override and
        // re-renders the greeting when the debug clock flips while this
        // tab is already on screen. Without this read, `AppClock.now()`
        // is an untracked side-effect and the greeting can sit on the
        // old fake/real time until something unrelated invalidates the
        // view.
        let _ = AppClockState.shared.version
        return ScrollView {
            VStack(spacing: TigerDuckTheme.Spacing.lg) {
                // Greeting
                HStack {
                    Text(AppClock.now().greetingText())
                        .font(TigerDuckTheme.Typography.title)
                        .foregroundStyle(Color.textPrimary)
                    Spacer()
                    NetworkStatusOverlay(
                        loadingState: appState.sessionManager.loadingState,
                        isLocalOnly: appState.isSyncLocalOnly
                    )
                    ServerStatusIcons(servers: [.moodle, .backend])
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
            // Long-press anywhere in the scroll content (empty space, section
            // headers, the course slider) enters edit mode. `longPressToEdit`
            // attaches it via `.simultaneousGesture` so on iOS 18 it coexists
            // with — rather than swallows — the first tap on every child
            // (widgets, course cards). See View+ScrollSafeGesture.
            .longPressToEdit(reduceMotion: reduceMotion) {
                if !viewModel.isEditingHome { viewModel.isEditingHome = true }
            }
        }
        .refreshable {
            // Fire-and-forget: the pull gesture should dismiss the
            // UIRefreshControl spinner immediately once released.
            // `triggerRefresh` coalesces rapid repeated pulls into a
            // single in-flight fetch; status lives in the top-right
            // NetworkStatusOverlay.
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
                    if #available(iOS 26, *) {
                        Button { showAddSection = true } label: {
                            Image(systemName: "plus")
                                .font(.body.weight(.medium))
                                .foregroundStyle(.primary)
                                .frame(width: 28, height: 28)
                                .glassEffect(.regular.interactive(), in: .circle)
                        }
                        .accessibilityLabel(Text("home_add_section_title"))
                    } else {
                        Button { showAddSection = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel(Text("home_add_section_title"))
                    }
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
        .alert(String(localized: "sync_conflict_title"), isPresented: Binding(
            get: { !appState.syncConflicts.isEmpty },
            set: { if !$0 { appState.resolveSyncConflicts(keepLocal: true) } }
        )) {
            Button(String(localized: "sync_conflict_use_server")) { appState.resolveSyncConflicts(keepLocal: false) }
            Button(String(localized: "sync_conflict_use_local"), role: .cancel) { appState.resolveSyncConflicts(keepLocal: true) }
        } message: {
            Text(appState.syncConflictAlertMessage)
        }
        .navigationDestination(item: $selectedFeature) { feature in
            homeDestination(for: feature)
        }
        .sheet(item: $viewModel.selectedCourse) { course in
            let slot = viewModel.selectedCourseSlot
            CourseDetailSheet(
                course: course,
                assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                timeRange: slot.map { "\($0.start.timeString) - \($0.end.timeString)" },
                weekday: slot?.date.scheduleWeekday ?? AppClock.now().scheduleWeekday
            )
            .presentationDetents([.medium, .large])
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
        .wiggling(viewModel.isEditingHome)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder
    private var upcomingAssignmentsContent: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            Picker("", selection: Bindable(viewModel).assignmentFilter) {
                ForEach(viewModel.availableAssignmentFilters, id: \.self) { filter in
                    Text(filter.displayName).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .disabled(viewModel.isEditingHome)

            switch appState.ntustProtectedAccessState(isEmpty: viewModel.upcomingAssignments.isEmpty) {
            case .loginRequired:
                LoginRequiredView(
                    layout: .section,
                    title: String(localized: "common_not_signed_in"),
                    message: String(localized: "home_assignments_sign_in_required_message"),
                    onPrimary: { appState.presentNTUSTLogin() }
                )
            case .empty:
                EmptyStateView(
                    icon: "checkmark.circle",
                    title: String(localized: "home_assignments_all_good"),
                    message: assignmentEmptyMessage
                )
            case .content:
                UpcomingAssignmentsView(
                    assignments: viewModel.upcomingAssignments,
                    courses: viewModel.allCourses,
                    filter: viewModel.assignmentFilter,
                    showAbsoluteTime: appState.showAbsoluteAssignmentTime,
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
                    }
                )
                .allowsHitTesting(!viewModel.isEditingHome)
            }
        }
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
