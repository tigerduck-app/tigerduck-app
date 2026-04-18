import SwiftUI

struct ClassTableView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = ClassTableViewModel()

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
                    titleBar

                    switch pageAccessState {
                    case .loginRequired:
                        LoginRequiredView(
                            layout: .page,
                            title: "尚未登入",
                            message: "尚未登入，無法查看課表",
                            onPrimary: { appState.presentNTUSTLogin() }
                        )
                    case .content, .empty, .loading, .error:
                        authenticatedContent
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
            .refreshable {
                await viewModel.refresh(authService: appState.authService)
            }
            .background(Color.backgroundPrimary)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .sheet(item: $viewModel.selectedCourse) { course in
                CourseDetailSheet(
                    course: course,
                    assignments: viewModel.assignmentsFor(courseNo: course.courseNo),
                    timeRange: viewModel.selectedCourseTimeRange,
                    weekday: viewModel.selectedWeekday
                )
                .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $viewModel.showAddCourse) {
                AddCourseSheet(
                    semester: viewModel.currentSemester,
                    existingCourseNos: Set(viewModel.courses.map(\.courseNo)),
                    onAdd: { viewModel.addCourse($0) }
                )
                .presentationDetents([.medium, .large])
            }
            .alert("重新命名", isPresented: $viewModel.showRenameAlert) {
                TextField("課程名稱", text: $viewModel.renameText)
                Button("確認") {
                    viewModel.confirmRename()
                }
                Button("取消", role: .cancel) {
                    viewModel.courseToRename = nil
                }
            }
    }

    /// Page-level access gate. The Class Table screen only makes sense when
    /// an NTUST session exists — the grid, credit total, and add-course
    /// action all assume authenticated data. Render a login prompt otherwise
    /// rather than a deceptively empty timetable.
    private var pageAccessState: NTUSTProtectedAccessState {
        NTUSTProtectedAccessState(
            isLoggedIn: appState.isNTUSTLoggedIn,
            isEmpty: viewModel.courses.isEmpty
        )
    }

    private var titleBar: some View {
        HStack {
            Text("課表")
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
            if appState.isNTUSTLoggedIn {
                Button {
                    viewModel.showAddCourse = true
                } label: {
                    Image(systemName: "plus")
                        .foregroundStyle(Color.textSecondary)
                }
            }
        }
        .padding(.horizontal, TigerDuckTheme.Spacing.lg)
        .padding(.top, TigerDuckTheme.Spacing.md)
    }

    private var authenticatedContent: some View {
        VStack(spacing: TigerDuckTheme.Spacing.lg) {
            if !viewModel.todayCourses.isEmpty {
                VStack(spacing: TigerDuckTheme.Spacing.sm) {
                    SectionHeader(title: "今日課程")
                    TodayCourseCarousel(
                        courses: viewModel.todayCourses,
                        hasAssignment: viewModel.hasAssignment,
                        showProgress: false,
                        onSelect: { viewModel.selectedCourse = $0 }
                    )
                }
            }

            // TODO: Implement semester picker (學年度 selection) once backend supports it
            HStack {
                Spacer()

                Text("\(viewModel.totalCredits) 學分")
                    .font(TigerDuckTheme.Typography.body)
                    .foregroundStyle(Color.textSecondary)
            }
            .padding(.horizontal)

            TimetableGridView(viewModel: viewModel)
        }
    }
}
