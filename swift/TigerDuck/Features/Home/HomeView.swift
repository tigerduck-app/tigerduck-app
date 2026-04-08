import SwiftUI

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var showNotImplementedAlert = false

    // Section drag state
    @State private var draggingSection: HomeSection?
    @State private var sectionDragLocation: CGPoint = .zero
    @State private var sectionFingerOffset: CGSize = .zero
    @State private var sectionFrames: [String: CGRect] = [:]

    var body: some View {
        NavigationStack {
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

                    // Sections
                    ForEach(viewModel.sections) { section in
                        sectionCell(section)
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
                .coordinateSpace(name: "sectionList")
                .onPreferenceChange(SectionFrameKey.self) { sectionFrames = $0 }
                .overlay { floatingSectionPreview }
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
                await viewModel.refresh(authService: appState.authService)
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
                                draggingSection = nil
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
            .sheet(item: $viewModel.selectedCourse) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    weekday: Date().scheduleWeekday
                )
                .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            viewModel.load(authService: appState.authService)
        }
    }

    // MARK: - Section cell with conditional drag

    @ViewBuilder
    private func sectionCell(_ section: HomeSection) -> some View {
        let content = sectionContent(section)

        if viewModel.isEditingHome {
            content.gesture(
                DragGesture(minimumDistance: 5, coordinateSpace: .named("sectionList"))
                    .onChanged { value in
                        if draggingSection == nil {
                            draggingSection = section
                            if let frame = sectionFrames[section.id] {
                                sectionFingerOffset = CGSize(
                                    width: value.startLocation.x - frame.midX,
                                    height: value.startLocation.y - frame.midY
                                )
                            }
                            sectionDragLocation = value.location
                            return
                        }
                        sectionDragLocation = value.location
                        reorderSectionsIfNeeded(at: value.location)
                    }
                    .onEnded { _ in
                        withAnimation(.smoothSpring) {
                            draggingSection = nil
                        }
                    }
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
                    // TODO: navigate to the feature
                } else {
                    showNotImplementedAlert = true
                }
            }
        )
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
        .opacity(draggingSection?.id == section.id ? 0 : 1)
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: SectionFrameKey.self,
                    value: [section.id: geo.frame(in: .named("sectionList"))]
                )
            }
        )
    }

    // MARK: - Floating section preview

    @ViewBuilder
    private var floatingSectionPreview: some View {
        if let dragging = draggingSection {
            HStack(spacing: TigerDuckTheme.Spacing.sm) {
                Image(systemName: dragging.type.iconName)
                    .font(.title3)
                    .foregroundStyle(Color.accentPrimary)
                Text(dragging.title)
                    .font(TigerDuckTheme.Typography.headline)
                    .foregroundStyle(.primary)
                Spacer()
            }
            .padding(TigerDuckTheme.Spacing.lg)
            .frame(width: 280, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TigerDuckTheme.CornerRadius.lg)
                    .fill(Color(.secondarySystemGroupedBackground))
                    .shadow(color: .black.opacity(0.25), radius: 12, x: 0, y: 6)
            )
            .scaleEffect(1.05)
            .position(
                x: sectionDragLocation.x - sectionFingerOffset.width,
                y: sectionDragLocation.y - sectionFingerOffset.height
            )
            .allowsHitTesting(false)
        }
    }

    // MARK: - Reorder sections

    private func reorderSectionsIfNeeded(at point: CGPoint) {
        guard let dragging = draggingSection,
              let fromIndex = viewModel.sections.firstIndex(where: { $0.id == dragging.id }) else { return }

        for (id, frame) in sectionFrames where id != dragging.id {
            if frame.contains(point),
               let toIndex = viewModel.sections.firstIndex(where: { $0.id == id }) {
                withAnimation(.smoothSpring) {
                    viewModel.sections.move(fromOffsets: IndexSet(integer: fromIndex),
                                            toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
                }
                return
            }
        }
    }
}

// MARK: - Section frame tracking

private struct SectionFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { $1 })
    }
}

// MARK: - Section content renderer

private struct HomeSectionView: View {
    let section: HomeSection
    let viewModel: HomeViewModel
    let appState: AppState
    var onFeatureTap: ((AppFeature) -> Void)? = nil

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            if section.type != .todayCourses {
                SectionHeader(title: section.title)
            }

            switch section.type {
            case .todayCourses:
                TimeSliderSection(
                    courses: viewModel.allCourses,
                    onSelectCourse: { viewModel.selectedCourse = $0 }
                )
            case .upcomingAssignments:
                if viewModel.upcomingAssignments.isEmpty {
                    EmptyStateView(
                        icon: "checkmark.circle",
                        title: "一切順利",
                        message: "沒有待辦作業"
                    )
                } else {
                    UpcomingAssignmentsView(
                        assignments: viewModel.upcomingAssignments,
                        showAbsoluteTime: appState.showAbsoluteAssignmentTime
                    )
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
                    isEditing: Binding(
                        get: { viewModel.isEditingHome },
                        set: { viewModel.isEditingHome = $0 }
                    ),
                    onRemove: { widget in
                        withAnimation(.smoothSpring) {
                            viewModel.removeWidget(from: section.id, widget: widget)
                        }
                    },
                    onTap: { feature in
                        onFeatureTap?(feature)
                    }
                )
            }
        }
    }
}
