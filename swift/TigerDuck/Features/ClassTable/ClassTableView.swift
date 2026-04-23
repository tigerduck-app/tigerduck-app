import SwiftUI

struct ClassTableView: View {
    var embedded = false

    @Environment(AppState.self) private var appState
    @State private var viewModel = ClassTableViewModel()

    var body: some View {
        if embedded {
            content
                .onAppear {
                    viewModel.load(authService: appState.authService)
                    Task { await viewModel.warmCachesIfNeeded(authService: appState.authService) }
                }
                .onChange(of: viewModel.currentSemester) { _, _ in
                    Task { await viewModel.refreshSelectedSemester(authService: appState.authService) }
                }
        } else {
            NavigationStack { content }
                .onAppear {
                    viewModel.load(authService: appState.authService)
                    Task { await viewModel.warmCachesIfNeeded(authService: appState.authService) }
                }
                .onChange(of: viewModel.currentSemester) { _, _ in
                    Task { await viewModel.refreshSelectedSemester(authService: appState.authService) }
                }
        }
    }

    private var content: some View {
        ScrollView {
                VStack(spacing: TigerDuckTheme.Spacing.lg) {
                    titleBar

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

                    switch pageAccessState {
                    case .loginRequired:
                        LoginRequiredView(
                            layout: .page,
                            title: "尚未登入",
                            message: "尚未登入，無法查看課表",
                            onPrimary: { appState.presentNTUSTLogin() }
                        )
                    case .empty:
                        // Keep the semester picker visible so the user can
                        // switch to a semester that does have courses even
                        // when the current semester's roster is empty.
                        VStack(spacing: TigerDuckTheme.Spacing.lg) {
                            if !viewModel.todayCourses.isEmpty {
                                todayCoursesSection
                            }
                            semesterPickerBar
                            EmptyStateView(
                                icon: "book.closed",
                                title: "目前沒有課程",
                                message: "下拉以重新整理，或使用右上角的 + 新增課程，或切換到其他學期"
                            )
                            .padding(.vertical, TigerDuckTheme.Spacing.xxl)
                        }
                    case .content:
                        authenticatedContent
                    }
                }
                .padding(.bottom, TigerDuckTheme.Spacing.xxl)
            }
            .scrollIndicators(.hidden)
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
            .sheet(item: $viewModel.courseToRecolor) { course in
                CourseColorPickerSheet(
                    course: course,
                    onSelect: { viewModel.setCustomColor(paletteIndex: $0, for: course) },
                    onReset: { viewModel.clearCustomColor(for: course) }
                )
                .presentationDetents([.medium])
            }
    }

    /// Page-level access gate for the Class Table screen. Delegates to the
    /// canonical ``AppState/ntustProtectedAccessState(isEmpty:)`` so the
    /// cached-first rule stays consistent with Home — a returning user
    /// with stored credentials and an expired cookie sees cached data (or
    /// an empty-state placeholder), never the interactive login prompt.
    private var pageAccessState: NTUSTProtectedAccessState {
        appState.ntustProtectedAccessState(isEmpty: viewModel.courses.isEmpty)
    }

    private var titleBar: some View {
        HStack {
            Text("課表")
                .font(TigerDuckTheme.Typography.title)
                .foregroundStyle(Color.textPrimary)
            Spacer()
            NetworkStatusOverlay(loadingState: appState.sessionManager.loadingState)
            if pageAccessState != .loginRequired {
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
                todayCoursesSection
            }
            semesterPickerBar

            TimetableGridView(viewModel: viewModel)
        }
    }

    private var todayCoursesSection: some View {
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

    /// Semester picker + credit total row. Extracted so it can be shown
    /// even when the current semester has no courses — otherwise the user
    /// has no way to pivot to a semester that does have data.
    private var semesterPickerBar: some View {
        HStack {
            Picker("學期", selection: $viewModel.currentSemester) {
                ForEach(viewModel.availableSemesters, id: \.self) { code in
                    Text(viewModel.displayLabel(for: code)).tag(code)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()

            Spacer()

            Text("\(viewModel.totalCredits) 學分")
                .font(TigerDuckTheme.Typography.body)
                .foregroundStyle(Color.textSecondary)
        }
        .padding(.horizontal)
    }
}
