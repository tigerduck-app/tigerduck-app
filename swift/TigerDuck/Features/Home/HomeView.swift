import SwiftUI
import UniformTypeIdentifiers

struct HomeView: View {
    @Environment(AppState.self) private var appState
    @State private var viewModel = HomeViewModel()
    @State private var showAddSection = false
    @State private var draggingSection: HomeSection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    // Greeting
                    HStack {
                        Text("\(Date().greetingText())，\(appState.username)")
                            .font(TigerDuckTheme.Typography.title)
                            .foregroundStyle(Color.textPrimary)
                        Spacer()
                        NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
                    }
                    .padding(.horizontal, TigerDuckTheme.Spacing.lg)
                    .padding(.top, TigerDuckTheme.Spacing.md)

                    // Sections
                    ForEach(viewModel.sections) { section in
                        HomeSectionView(
                            section: section,
                            viewModel: viewModel,
                            appState: appState
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
                        .onDrag {
                            draggingSection = section
                            return NSItemProvider(object: section.id as NSString)
                        }
                        .onDrop(
                            of: [UTType.text],
                            delegate: SectionDropDelegate(
                                targetSection: section,
                                sections: $viewModel.sections,
                                draggingSection: $draggingSection
                            )
                        )
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
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
            .sheet(item: $viewModel.selectedCourse) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo)
                )
                .presentationDetents([.medium, .large])
            }
        }
        .onAppear {
            viewModel.load(authService: appState.authService)
        }
    }
}

// MARK: - Drop delegate for real-time section reordering

private struct SectionDropDelegate: DropDelegate {
    let targetSection: HomeSection
    @Binding var sections: [HomeSection]
    @Binding var draggingSection: HomeSection?

    func dropEntered(info: DropInfo) {
        guard let dragging = draggingSection,
              dragging.id != targetSection.id,
              let fromIndex = sections.firstIndex(where: { $0.id == dragging.id }),
              let toIndex = sections.firstIndex(where: { $0.id == targetSection.id }) else { return }
        withAnimation(.smoothSpring) {
            sections.move(fromOffsets: IndexSet(integer: fromIndex),
                          toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        draggingSection = nil
        return true
    }

    func dropExited(info: DropInfo) {
        // No-op
    }
}

// MARK: - Section content renderer

private struct HomeSectionView: View {
    let section: HomeSection
    let viewModel: HomeViewModel
    let appState: AppState

    var body: some View {
        VStack(spacing: TigerDuckTheme.Spacing.sm) {
            SectionHeader(title: section.title)

            switch section.type {
            case .todayCourses:
                TodayCourseCarousel(
                    courses: viewModel.todayCourses,
                    hasAssignment: viewModel.hasUnfinishedAssignment,
                    onSelect: { viewModel.selectedCourse = $0 }
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
                    onTap: { _ in }
                )
            }
        }
    }
}
